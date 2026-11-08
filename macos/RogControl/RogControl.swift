// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// RogControl: a small ROG Control Center for macOS on the GA403WM (ROG Zephyrus G14 2025): performance mode (Silent,
// Balanced, Turbo, Manual power limits), battery charge limit, CPU temperature / package power / fan speeds, GPU MUX
// state. Settings are kept per power source (AC / battery) and applied again when the source changes and at login, as asusd
// does. Native app window and menu bar popover, SwiftUI, SF Symbols only.
//
// Inspired by asusctl / rog-control-center (asus-linux.org, Luke Jones and contributors, MPL-2.0); no code is taken from it.
// Talks to kexts/AsusWmi through its user client (ABI: kexts/AsusWmi/asuswmi_abi.h, no sudo) and reads the sysctl
// debug.amdcppc.sensors of kexts/AmdCppc.
//
// Command line (same binary):
//   RogControl --bench [seconds]   runs Silent, Balanced and Turbo in turn under full load on every CPU and prints package
//                                  power, Tctl, fan speeds and clocks per mode; puts the previous mode back afterwards
// Build: scripts/build-rogcontrol.sh
import AppKit
import SwiftUI
import Charts
import IOKit
import IOKit.ps
import IOKit.kext
import CoreAudio
import CoreMediaIO

// ---- driver access (asuswmi_abi.h) -----------------------------------------------------------------------------------------
struct AsusState {
    var present = false, ac = true, fanCustom = false
    var profile: Int? = nil, charge: Int? = nil
    var cpuFan = 0, gpuFan = 0
    var ppt = [0, 0, 0]
    var ranges = [(15, 80), (25, 80), (35, 80)]
    var gpuMux: UInt32 = ~0, dgpu: UInt32 = ~0, baseTgp = 0
    var backlight: Int? = nil, backlightMax = 0
    var batDesign = 0, batFull = 0, batNow = 0, batState = 0, batRate = 0   // mAh, mAh, mAh, _BST state, mA
    var kbd: Int? = nil, slash: Int? = nil, hid = false                   // ABI 3: keyboard light 0..3, Slash (packed), N-KEY seen
    var lighting = false                                                    // the kext has the keyboard / Slash settings
    var abi: UInt32 = 0                                                     // AsusWmi's ABI version, 0 = not loaded
    var aura: Int? = nil, hasAura = false                                   // ABI 5: keyboard Aura mode 0..2
}

// Slash lighting (asuswmi_abi.h ASUS_SLASH_*): mode index, brightness 0..3 (0 = off), interval 0..5
struct Slash: Equatable {
    static let modes = ["Static", "Bounce", "Slash", "Loading", "Bit Stream", "Transmission", "Flow", "Flux",
                        "Phantom", "Spectrum", "Hazard", "Interfacing", "Ramp", "Game Over", "Start", "Buzzer"]
    var mode = 2, bright = 2, interval = 0
    var packed: Int { mode | (bright << 8) | (interval << 12) }
    init(mode: Int = 2, bright: Int = 2, interval: Int = 0) { self.mode = mode; self.bright = bright; self.interval = interval }
    init(packed v: Int) { mode = v & 0xff; bright = (v >> 8) & 0xf; interval = (v >> 12) & 0xf }
}

enum Asus {
    static let abi: UInt32 = 5                                    // ABI 4 added the key selector, ABI 5 the Aura word and setting
    enum Sel: UInt32 { case state = 0, set = 1, fanRead = 2, fanWrite = 3, fanReset = 4 }
    enum What: UInt64 { case profile = 1, spl = 2, sppt = 3, fppt = 4, charge = 5, backlight = 6, kbd = 7, slash = 8, aura = 9 }

    static func open() -> io_connect_t? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AsusWmi"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        return IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS ? conn : nil
    }

    static func call(_ sel: Sel, scalars: [UInt64] = [], input: [UInt8]? = nil, outCount: Int = 0) -> (kern_return_t, [UInt8]) {
        guard let c = open() else { return (kIOReturnNotFound, []) }
        defer { IOServiceClose(c) }
        var out = [UInt8](repeating: 0, count: outCount)
        var outSize = outCount
        var sc = scalars
        let inp = input ?? []
        let kr: kern_return_t = sc.withUnsafeMutableBufferPointer { sb in
            inp.withUnsafeBytes { ib in
                out.withUnsafeMutableBytes { ob in
                    IOConnectCallMethod(c, sel.rawValue, sb.baseAddress, UInt32(sb.count), inp.isEmpty ? nil : ib.baseAddress, ib.count,
                                        nil, nil, outCount > 0 ? ob.baseAddress : nil, &outSize)
                }
            }
        }
        return (kr, Array(out.prefix(outSize)))
    }

    static func state() -> AsusState {
        var s = AsusState()
        let (kr, b) = call(.state, outCount: 28 * 4)
        guard kr == KERN_SUCCESS, b.count >= 24 * 4 else { return s }
        func w(_ i: Int) -> UInt32 { b.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: UInt32.self) } }
        guard w(0) >= 1, w(0) <= abi else { return s }          // ABI 1 / 2 (fewer words) still work
        s.present = true; s.abi = w(0)
        s.ac = w(1) & 1 != 0; s.fanCustom = w(1) & 2 != 0
        s.profile = w(2) == ~0 ? nil : Int(w(2)); s.charge = w(3) == ~0 ? nil : Int(w(3))
        s.cpuFan = Int(w(4)); s.gpuFan = Int(w(5))
        s.ppt = [Int(w(6)), Int(w(7)), Int(w(8))]
        s.ranges = [(Int(w(9)), Int(w(10))), (Int(w(11)), Int(w(12))), (Int(w(13)), Int(w(14)))]
        s.gpuMux = w(15); s.dgpu = w(16); s.baseTgp = Int(w(17))
        guard w(0) >= 2 else { return s }
        s.backlight = w(18) == ~0 ? nil : Int(w(18)); s.backlightMax = Int(w(19))
        s.batDesign = Int(w(20)); s.batFull = Int(w(21)); s.batNow = Int(w(22))
        s.batState = Int(w(23) & 0xff); s.batRate = Int(w(23) >> 8)
        guard w(0) >= 3, b.count >= 27 * 4 else { return s }
        s.lighting = true
        s.kbd = w(24) == ~0 ? nil : Int(w(24)); s.slash = w(25) == ~0 ? nil : Int(w(25)); s.hid = w(26) != 0
        guard w(0) >= 5, b.count >= 28 * 4 else { return s }
        s.hasAura = true; s.aura = w(27) == ~0 ? nil : Int(w(27))
        return s
    }

    @discardableResult static func set(_ what: What, _ v: Int) -> kern_return_t { call(.set, scalars: [what.rawValue, UInt64(v)]).0 }
    static func fanCurve(fan: Int, profile: Int) -> [UInt8]? {
        let (kr, b) = call(.fanRead, scalars: [UInt64(fan), UInt64(profile)], outCount: 16)
        return kr == KERN_SUCCESS && b.count == 16 ? b : nil
    }
    @discardableResult static func setFanCurve(fan: Int, _ c: [UInt8]) -> kern_return_t { call(.fanWrite, scalars: [UInt64(fan)], input: c).0 }
    @discardableResult static func fanReset() -> kern_return_t { call(.fanReset).0 }
}

// AmdCppc: "tctl=<m°C> pkg_mw=<mW>" (power averaged since the previous read) and the per-CPU clock report
enum Sensors {
    static func string(_ name: String) -> String? {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len + 1)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    // "<sequence> <code>" of the last Fn key AsusWmi saw (codes from the N-KEY keyboard, passed in by rogkeyd)
    static func hotkey() -> (sequence: UInt32, code: UInt32)? {
        guard let v = string("debug.asuswmi.hotkey") else { return nil }
        let p = v.split(separator: " ")
        guard p.count == 2, let sq = UInt32(p[0]), let c = UInt32(p[1]) else { return nil }
        return (sq, c)
    }
    static func read() -> (tctl: Double?, watts: Double?) {
        guard let s = string("debug.amdcppc.sensors") else { return (nil, nil) }
        var t: Double?, w: Double?
        for kv in s.split(separator: " ") {
            let p = kv.split(separator: "="); guard p.count == 2, let v = Double(p[1]) else { continue }
            if p[0] == "tctl", v > -1 { t = v / 1000 }
            if p[0] == "pkg_mw", v > 0 { w = v / 1000 }
        }
        return (t, w)
    }
    // average effective MHz of the busy CPUs 0-7 (Zen 5) and 8-23 (Zen 5c) from debug.amdcppc.freq
    static func clocks() -> (big: Int, little: Int)? {
        guard let s = string("debug.amdcppc.freq") else { return nil }
        var big: [Int] = [], little: [Int] = []
        for part in s.split(separator: "|").dropFirst() {
            let f = part.split(separator: " ")
            guard f.count >= 2, let cpu = Int(f[0]) else { continue }
            let v = f[1].split(separator: "/")
            guard v.count >= 2, let mhz = Int(v[0]), let busy = Int(v[1].dropLast()), busy >= 50 else { continue }
            if cpu < 8 { big.append(mhz) } else { little.append(mhz) }
        }
        func avg(_ a: [Int]) -> Int { a.isEmpty ? 0 : a.reduce(0, +) / a.count }
        return (avg(big), avg(little))
    }
}

// ---- modes and settings ------------------------------------------------------------------------------------------------------
// ---- sound, microphone, camera ------------------------------------------------------------------------------------------------
// RogAudio (installed on its own: RogAudio.driver + rogaudiod) adds "ROG Speakers", a sound profile chain in front of the built-in
// speakers, and "ROG Clear Mic", the noise-reduced built-in mic. ROG Control talks to it only through its settings file, which
// rogaudiod re-reads every 250 ms (profile, micEnabled, autoDefault), and reads its status file. The firmware has no camera switch
// and no mic-mute LED (ATKD answers "unsupported" for 0x00040017 and has no 0x00060013), so mute and camera state are plain
// CoreAudio and CoreMediaIO. Nothing here asks for microphone or camera access: only device properties are read.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID, uid: String, name: String, builtin: Bool
    var isRogSpeakers: Bool { uid == Sound.speakersUID }
    var label: String { isRogSpeakers ? "ROG Speakers" : builtin ? "Built-in, no profile" : name }
}

struct SoundState {
    var outputs: [AudioDevice] = []
    var output: AudioDevice?             // default output
    var input: AudioDevice?              // default input
    var rog = false                      // the ROG Speakers device exists (RogAudio.driver installed)
    var daemon = false                   // rogaudiod wrote its status file in the last 10 s
    var chain = false                    // rogaudiod's speaker path is running
    var profile = "balanced"
    var clearMic = false                 // settings micEnabled
    var micMuted: Bool?                  // built-in mic mute; nil when there is no built-in mic
    var micInUse = false
    var camera: String?                  // camera name; nil when none is attached
    var cameraInUse = false
}

enum Sound {
    static let speakersUID = "com.itlmt7925.rogaudio.speakers", micUID = "com.itlmt7925.rogaudio.mic"
    static let profiles = ["off", "balanced", "movie", "music", "voice"]
    static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RogAudio") }
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ e: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: e)
    }
    static func u32(_ d: AudioObjectID, _ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = addr(s, sc), v: UInt32 = 0, n = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &n, &v) == 0 ? v : nil
    }
    static func string(_ d: AudioObjectID, _ s: AudioObjectPropertySelector) -> String? {
        var a = addr(s), v: Unmanaged<CFString>?, n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &n, &v) == 0, let r = v?.takeRetainedValue() else { return nil }
        return r as String
    }
    static func streams(_ d: AudioObjectID, input: Bool) -> Int {
        var a = addr(kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput), n: UInt32 = 0
        return AudioObjectGetPropertyDataSize(d, &a, 0, nil, &n) == 0 ? Int(n) / 4 : 0
    }
    static func ids() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices), n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &n) == 0, n > 0 else { return [] }
        var v = [AudioObjectID](repeating: 0, count: Int(n) / 4)
        return AudioObjectGetPropertyData(system, &a, 0, nil, &n, &v) == 0 ? v : []
    }
    static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard id != 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                           builtin: !uid.hasPrefix("com.itlmt7925.") && u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn)
    }
    static func defaultID(input: Bool) -> AudioObjectID {
        u32(system, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice) ?? 0
    }
    static func setDefault(_ id: AudioObjectID, input: Bool) -> Bool {
        var v = id
        let sels = input ? [kAudioHardwarePropertyDefaultInputDevice]
                         : [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
        return sels.allSatisfy { sel in var a = addr(sel); return AudioObjectSetPropertyData(system, &a, 0, nil, 4, &v) == 0 }
    }
    static func running(_ id: AudioObjectID) -> Bool { (u32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 }
    static func byUID(_ uid: String) -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice), s = uid as CFString, d: AudioObjectID = 0, n = UInt32(4)
        let rc = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &n, &d) }
        return rc == 0 && d != 0 ? d : nil
    }
    static func builtinInput() -> AudioObjectID? {
        ids().first { streams($0, input: true) > 0 && device($0)?.builtin == true }
    }
    static func mute(_ d: AudioObjectID) -> Bool? { u32(d, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput).map { $0 != 0 } }
    static func setMute(_ d: AudioObjectID, _ on: Bool) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput), v: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &v) == 0
    }

    static func plist(_ name: String) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return [:] }
        return p
    }
    // merges the change into rogaudiod's settings file (strixampctl reads the same file for the amp volume and mute)
    static func write(_ change: [String: Any]) -> Bool {
        var p = plist("settings.plist")
        for (k, v) in change { p[k] = v }
        guard let d = try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? d.write(to: dir.appendingPathComponent("settings.plist"), options: .atomic)) != nil
    }

    static func state() -> SoundState {
        var st = SoundState()
        let all = ids()
        st.outputs = all.filter { streams($0, input: false) > 0 && u32($0, kAudioDevicePropertyIsHidden) != 1 }.compactMap(device)
        st.output = device(defaultID(input: false))
        st.input = device(defaultID(input: true))
        st.rog = st.outputs.contains { $0.isRogSpeakers }
        let status = plist("status.plist"), settings = plist("settings.plist")
        let updated = (status["updated"] as? Double) ?? 0
        st.daemon = abs(Date().timeIntervalSince1970 - updated) < 10
        st.chain = st.daemon && (status["speakerActive"] as? Bool ?? false)
        st.profile = settings["profile"] as? String ?? "balanced"
        st.clearMic = settings["micEnabled"] as? Bool ?? false
        if let mic = builtinInput() {
            st.micMuted = mute(mic)
            st.micInUse = running(mic) || (byUID(micUID).map(running) ?? false)
        }
        (st.camera, st.cameraInUse) = Camera.state()
        return st
    }
}

enum Camera {
    static func addr(_ s: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(s), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    // the first video device and whether any app is capturing from it (the green light)
    static func state() -> (String?, Bool) {
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        var a = addr(kCMIOHardwarePropertyDevices), n: UInt32 = 0, used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(sys, &a, 0, nil, &n) == 0, n > 0 else { return (nil, false) }
        var ids = [CMIOObjectID](repeating: 0, count: Int(n) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(sys, &a, 0, nil, n, &used, &ids) == 0, let cam = ids.first else { return (nil, false) }
        var na = addr(kCMIOObjectPropertyName), name: Unmanaged<CFString>?
        let nameOK = CMIOObjectGetPropertyData(cam, &na, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &name) == 0
        var ra = addr(kCMIODevicePropertyDeviceIsRunningSomewhere), run: UInt32 = 0
        _ = CMIOObjectGetPropertyData(cam, &ra, 0, nil, 4, &used, &run)
        return (nameOK ? (name?.takeRetainedValue() as String?) ?? "Camera" : "Camera", run != 0)
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case silent, performance, turbo, manual
    var id: String { rawValue }
    var title: String { ["silent": "Silent", "performance": "Balanced", "turbo": "Turbo", "manual": "Custom"][rawValue]! }   // manual is shown as Custom
    var symbol: String {
        // one family: filled glyphs at one weight, drawn in the same chamfered badge (ModeBadge)
        ["silent": "leaf.fill", "performance": "gauge.with.needle.fill", "turbo": "flame.fill", "manual": "dial.low.fill"][rawValue]!
    }
    var firmwareProfile: Int { self == .silent ? 2 : self == .turbo ? 1 : 0 }   // asus-wmi: 0 balanced, 1 overboost, 2 silent
    static func from(profile: Int?) -> Mode? { profile == 2 ? .silent : profile == 1 ? .turbo : profile == 0 ? .performance : nil }
}

// One setting set per power source, in UserDefaults ("ac.mode", "battery.spl", ...)
struct SourceSettings {
    var mode: Mode
    var spl: Int, sppt: Int, fppt: Int
    var fanBase: Mode            // whose firmware fan curve Manual uses (silent / performance / turbo)
    static func load(ac: Bool) -> SourceSettings {
        let d = UserDefaults.standard, k = ac ? "ac." : "battery."
        func i(_ n: String, _ def: Int) -> Int { d.object(forKey: k + n) == nil ? def : d.integer(forKey: k + n) }
        return SourceSettings(mode: Mode(rawValue: d.string(forKey: k + "mode") ?? "") ?? .performance,
                              spl: i("spl", ac ? 45 : 30), sppt: i("sppt", ac ? 65 : 35), fppt: i("fppt", ac ? 80 : 50),
                              fanBase: Mode(rawValue: d.string(forKey: k + "fanBase") ?? "") ?? .performance)
    }
    func save(ac: Bool) {
        let d = UserDefaults.standard, k = ac ? "ac." : "battery."
        d.set(mode.rawValue, forKey: k + "mode"); d.set(spl, forKey: k + "spl"); d.set(sppt, forKey: k + "sppt")
        d.set(fppt, forKey: k + "fppt"); d.set(fanBase.rawValue, forKey: k + "fanBase")
    }
}

// ---- login item (a user LaunchAgent; no signing needed) ------------------------------------------------------------------
enum LoginItem {
    static let label = "com.itlmt7925.RogControl"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    static func set(_ on: Bool) {
        if !on { try? FileManager.default.removeItem(at: plist); return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let d: [String: Any] = ["Label": label, "ProgramArguments": [exe, "--background"], "RunAtLoad": true, "ProcessType": "Interactive",
                                "LimitLoadToSessionType": "Aqua"]
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        (d as NSDictionary).write(to: plist, atomically: true)
    }
}

// ---- apply ---------------------------------------------------------------------------------------------------------------
enum Apply {
    // Returns an error text or nil. Manual: profile first (fresh firmware state), then the chosen firmware fan curves as custom
    // curves (needed for power limits on this board), then the limits, kept in order SPL <= SPPT <= FPPT and in range.
    static func mode(_ s: SourceSettings, state st: AsusState) -> String? {
        var m = s.mode
        if m == .turbo && !st.ac { m = .performance }               // as Armoury Crate: no Turbo on battery
        if m != .manual {
            return Asus.set(.profile, m.firmwareProfile) == KERN_SUCCESS ? nil : "could not set the profile"
        }
        guard Asus.set(.profile, Mode.performance.firmwareProfile) == KERN_SUCCESS else { return "could not set the profile" }
        let base = s.fanBase == .turbo && !st.ac ? Mode.performance : s.fanBase
        for fan in 0..<2 {
            guard let c = Asus.fanCurve(fan: fan, profile: base.firmwareProfile) else { return "could not read the fan curve" }
            guard Asus.setFanCurve(fan: fan, c) == KERN_SUCCESS else { return "the fan curve was refused" }
        }
        let r = st.ranges
        let spl = min(max(s.spl, r[0].0), r[0].1)
        let sppt = min(max(max(s.sppt, spl), r[1].0), r[1].1)
        let fppt = min(max(max(s.fppt, sppt), r[2].0), r[2].1)
        for (w, v) in [(Asus.What.spl, spl), (.sppt, sppt), (.fppt, fppt)] where Asus.set(w, v) != KERN_SUCCESS {
            return "power limit \(v) W was refused"
        }
        return nil
    }
}

// ---- model -------------------------------------------------------------------------------------------------------------------
@MainActor
final class RogModel: ObservableObject {
    @Published var st = AsusState()
    @Published var tctl: Double?
    @Published var watts: Double?
    @Published var settings = SourceSettings.load(ac: true)
    @Published var charge = UserDefaults.standard.object(forKey: "charge") == nil ? 100 : UserDefaults.standard.integer(forKey: "charge")
    @Published var kbd = UserDefaults.standard.object(forKey: "kbd") == nil ? 2 : UserDefaults.standard.integer(forKey: "kbd")
    @Published var slash = UserDefaults.standard.object(forKey: "slash") == nil ? Slash() : Slash(packed: UserDefaults.standard.integer(forKey: "slash"))
    @Published var message = ""
    @Published var loginEnabled = LoginItem.enabled
    @Published var curve: [UInt8]? = nil
    @Published var gpuCurve: [UInt8]? = nil
    @Published var curveMode: Mode = .performance
    @Published var profileError = ""
    @Published var chargeError = ""
    @Published var lightingError = ""
    @Published var sound = SoundState()
    @Published var soundError = ""
    @Published var doctor: [DoctorCheck] = []
    func runDoctor() { doctor = Doctor.run(self) }
    private var doctorTick = 0
    struct Sample: Identifiable { let id: Int; let date: Date; let temp: Double; let watts: Double? }
    @Published var history: [Sample] = []
    private var sampleID = 0
    var activeMode: Mode? { st.present ? (st.fanCustom ? .manual : Mode.from(profile: st.profile)) : nil }
    var modeLabel: String { activeMode?.title ?? "Unavailable" }
    var currentSlash: Slash { st.slash.map { Slash(packed: $0) } ?? slash }
    var manualDirty: Bool {
        let saved = SourceSettings.load(ac: st.ac)
        return settings.spl != saved.spl || settings.sppt != saved.sppt || settings.fppt != saved.fppt || settings.fanBase != saved.fanBase
    }
    var onChange: (() -> Void)?
    // window navigation, so the popover can open a given page
    @Published var dialog: RogDialog? = nil     // the window's open dialog, if any
    // what ROG Control did on its own (power source change); shown for a few minutes
    @Published var autoNote = ""
    var autoNoteAt: Date?
    var recentAutoNote: String? {
        guard let at = autoNoteAt, Date().timeIntervalSince(at) < 600, !autoNote.isEmpty else { return nil }
        return autoNote
    }
    // Custom (manual) is "set up" once its limits were saved from Advanced, or it was already in use
    var customReady: Bool { UserDefaults.standard.bool(forKey: "custom.saved") || settings.mode == .manual }
    private var timer: Timer?
    private var lastAC: Bool?
    var visible = false { didSet { schedule() } }

    // Snapshot / preview: fixed state, never touches the driver (no reads, no writes, no timer)
    init(preview st: AsusState, tctl: Double?, watts: Double?, curve: [UInt8]?, gpuCurve: [UInt8]?) {
        self.st = st; self.tctl = tctl; self.watts = watts; self.curve = curve; self.gpuCurve = gpuCurve
        settings = SourceSettings(mode: Mode.from(profile: st.profile) ?? .performance, spl: 45, sppt: 65, fppt: 80, fanBase: .performance)
        charge = st.charge ?? 80; kbd = st.kbd ?? 2; slash = st.slash.map { Slash(packed: $0) } ?? Slash()
        curveMode = settings.mode; preview = true
    }
    var preview = false

    init() {
        refresh()
        // first run: keep what the firmware is doing now instead of imposing a default
        let d = UserDefaults.standard
        if st.present, d.string(forKey: st.ac ? "ac.mode" : "battery.mode") == nil, let m = Mode.from(profile: st.profile) {
            var s = SourceSettings.load(ac: st.ac); s.mode = m; s.save(ac: st.ac)
        }
        if st.present, d.object(forKey: "charge") == nil, let c = st.charge, (20...100).contains(c) { charge = c; d.set(c, forKey: "charge") }
        settings = SourceSettings.load(ac: st.ac)
        applyAll(reason: "start")
        applyLighting()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // the keyboard comes back from sleep with its own defaults: give it a moment, then send ours again
            // bind self once (a `self?` inside the delayed closure is a captured weak var, which older toolchains reject there)
            guard let model = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { model.applyLighting() } }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<RogModel>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { m.powerChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        schedule()
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: visible ? 2 : 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private var tSmooth: Double?, wSmooth: Double?
    static func ema(_ old: Double?, _ new: Double?, _ alpha: Double) -> Double? {
        guard let n = new else { return nil }
        guard let o = old else { return n }
        return o + alpha * (n - o)
    }
    static func hold(_ shown: Double?, _ new: Double?, step: Double) -> Double? {
        guard let n = new else { return nil }
        guard let o = shown, abs(n - o) < step else { return n.rounded() }
        return o
    }
    func refresh() {
        let previousMode = activeMode
        st = Asus.state()
        let s = Sensors.read()
        // The raw readings drift by fractions of a degree and jump by several watts between reads. Smooth them, then show whole
        // degrees and watts that only move when the smoothed value is a full step (1 °C, 2 W) away, so the numbers and gauges
        // stay still unless the temperature or power really changed.
        tSmooth = Self.ema(tSmooth, s.tctl, 0.25); wSmooth = Self.ema(wSmooth, s.watts, 0.2)
        let newT = Self.hold(tctl, tSmooth, step: 1.0), newW = Self.hold(watts, wSmooth, step: 2.0)
        if newT != tctl { tctl = newT }
        if newW != watts { watts = newW }
        if let t = tSmooth {
            sampleID += 1
            history.append(Sample(id: sampleID, date: Date(), temp: t, watts: wSmooth))
            if history.count > 180 { history.removeFirst(history.count - 180) }   // 6 min at the 2 s visible rate
        }
        if st.present, lastAC != nil, lastAC != st.ac { powerChanged() }
        lastAC = st.ac
        if previousMode != activeMode { loadCurve() }
        if !preview { sound = Sound.state() }
        doctorTick += 1
        if !preview, visible, doctorTick % 15 == 0 || doctor.isEmpty { runDoctor() }   // every 30 s while the window shows
        onChange?()
    }

    func powerChanged() {
        let now = Asus.state()
        guard now.present, now.ac != lastAC else { return }
        st = now; lastAC = now.ac
        settings = SourceSettings.load(ac: now.ac)
        applyAll(reason: now.ac ? "on AC" : "on battery")
        autoNote = "Switched to \(settings.mode.title) when the charger was \(now.ac ? "plugged in" : "unplugged")"
        autoNoteAt = Date()
    }

    func applyAll(reason: String) {
        guard st.present else { message = "AsusWmi is not loaded"; return }
        profileError = Apply.mode(settings, state: st) ?? ""
        chargeError = ""
        if st.charge != charge, Asus.set(.charge, charge) != KERN_SUCCESS { chargeError = "Charge limit was not applied." }
        st = Asus.state()
        loadCurve()
        let errs = [profileError, chargeError].filter { !$0.isEmpty }
        message = errs.isEmpty ? "\(settings.mode.title) applied (\(reason))" : errs.joined(separator: "; ")
        onChange?()
    }

    func choose(_ m: Mode) {
        settings.mode = m
        settings.save(ac: st.ac)
        applyAll(reason: st.ac ? "AC" : "battery")
    }
    func saveManual() { settings.save(ac: st.ac); applyAll(reason: "manual limits") }
    func setCharge(_ v: Int) {
        charge = v; UserDefaults.standard.set(v, forKey: "charge")
        chargeError = Asus.set(.charge, v) == KERN_SUCCESS ? "" : "Charge limit was not applied."
        message = chargeError.isEmpty ? "charge limit \(v) %" : chargeError
        st = Asus.state()
    }
    func applyLighting() {
        guard st.lighting else { return }
        var errs: [String] = []
        if Asus.set(.kbd, kbd) != KERN_SUCCESS { errs.append("keyboard light refused") }
        if Asus.set(.slash, slash.packed) != KERN_SUCCESS { errs.append("Slash refused") }
        st = Asus.state()
        lightingError = errs.joined(separator: "; ")
        if !errs.isEmpty { message = lightingError }
    }
    func setKbd(_ v: Int) {
        kbd = v; UserDefaults.standard.set(v, forKey: "kbd")
        lightingError = Asus.set(.kbd, v) == KERN_SUCCESS ? "" : "Keyboard light was not applied. Check the keyboard connection."
        message = lightingError.isEmpty ? "keyboard light \(v)" : lightingError
        st = Asus.state()
    }
    func setAura(_ v: Int) {
        lightingError = Asus.set(.aura, v) == KERN_SUCCESS ? "" : "Aura mode was not applied. Check the keyboard connection."
        message = lightingError.isEmpty ? "Aura \(LightingTile.auraModes[v])" : lightingError
        st = Asus.state()
    }
    func setSlash(_ s: Slash) {
        slash = s; UserDefaults.standard.set(s.packed, forKey: "slash")
        lightingError = Asus.set(.slash, s.packed) == KERN_SUCCESS ? "" : "Slash lighting was not applied. Check the keyboard connection."
        message = lightingError.isEmpty ? (s.bright == 0 ? "Slash off" : "Slash \(Slash.modes[s.mode])") : lightingError
        st = Asus.state()
    }
    var batteryLine: String {
        guard st.batDesign > 5 else { return "battery data not available from the firmware" }
        var s = ""
        if st.batFull > 0 { s += String(format: "health %.0f %% (%d / %d mAh)", 100.0 * Double(st.batFull) / Double(st.batDesign), st.batFull, st.batDesign) }
        if st.batFull > 0, st.batNow > 0 { s += String(format: " · %.0f %%", 100.0 * Double(st.batNow) / Double(st.batFull)) }
        if st.batState & 2 != 0 { s += " · charging \(st.batRate) mA" } else if st.batState & 1 != 0 { s += " · \(st.batRate) mA" }
        return s
    }
    func loadCurve() {
        // Manual shows the selected firmware reference, not an editable or measured RPM curve.
        curveMode = settings.mode == .manual ? settings.fanBase : (Mode.from(profile: st.profile) ?? .performance)
        if curveMode == .turbo && !st.ac { curveMode = .performance }
        curve = st.present ? Asus.fanCurve(fan: 0, profile: curveMode.firmwareProfile) : nil
        gpuCurve = st.present ? Asus.fanCurve(fan: 1, profile: curveMode.firmwareProfile) : nil
    }
    func setLogin(_ on: Bool) { LoginItem.set(on); loginEnabled = LoginItem.enabled }

    // ---- sound
    // Built-in chosen by hand means "no profile": rogaudiod would otherwise move the default straight back to ROG Speakers.
    func setOutput(_ d: AudioDevice) {
        if sound.rog, !Sound.write(["autoDefault": !d.builtin]) { soundError = "RogAudio settings could not be saved."; return }
        soundError = Sound.setDefault(d.id, input: false) ? "" : "\(d.label) could not be made the output."
        sound = Sound.state()
    }
    func setProfile(_ p: String) {
        soundError = Sound.write(["profile": p]) ? "" : "The sound profile was not saved."
        sound = Sound.state()
    }
    // Clear Mic off: apps that record from ROG Clear Mic would get silence, so the built-in mic becomes the input again
    func setClearMic(_ on: Bool) {
        guard Sound.write(["micEnabled": on]) else { soundError = "Clear Mic setting was not saved."; return }
        let target = on ? Sound.byUID(Sound.micUID) : (sound.input?.uid == Sound.micUID ? Sound.builtinInput() : nil)
        if let t = target, !Sound.setDefault(t, input: true) { soundError = "The input device was not changed." } else { soundError = "" }
        sound = Sound.state()
    }
    // mutes the built-in mic itself, so the direct input and ROG Clear Mic both go silent
    func setMicMute(_ on: Bool) {
        guard let mic = Sound.builtinInput(), Sound.setMute(mic, on) else { soundError = "The microphone could not be \(on ? "muted" : "unmuted")."; return }
        soundError = ""
        sound = Sound.state()
    }
    // the mode each power source uses; the current one is applied, the other is only saved
    func mode(forAC ac: Bool) -> Mode { ac == st.ac ? settings.mode : SourceSettings.load(ac: ac).mode }
    func setMode(_ mode: Mode, forAC ac: Bool) {
        if ac == st.ac { choose(mode); return }
        var s = SourceSettings.load(ac: ac); s.mode = mode; s.save(ac: ac)
        objectWillChange.send()
    }
    func saveCustom() {
        UserDefaults.standard.set(true, forKey: "custom.saved")
        settings.mode = .manual
        settings.save(ac: st.ac)
        applyAll(reason: "custom limits")
    }
    func resetCustom() {
        let saved = SourceSettings.load(ac: st.ac)
        settings.spl = saved.spl; settings.sppt = saved.sppt; settings.fppt = saved.fppt; settings.fanBase = saved.fanBase
        loadCurve()
    }
    func seedHistory() {
        let now = Date()
        history = (0..<120).map { i in
            let x = Double(i)
            let t: Double = 70 + 5 * sin(x / 11) + 2 * sin(x / 3)
            let w: Double = 36 + 9 * sin(x / 7 + 1) + 3 * sin(x / 2)
            return Sample(id: i, date: now.addingTimeInterval(Double(i - 120) * 2), temp: t, watts: w)
        }
    }
}

// ---- views ---------------------------------------------------------------------------------------------------------------------
// Two surfaces. The menu bar panel is native (system materials and accent) and holds only what is used daily: the mode, why the
// machine is hot or loud, the charge limit and the keyboard light. The window is the ROG side: dark, one red accent, chamfered
// cards and the Slash bar's slanted segments as its graphic language; it holds setup (power sources, Custom limits, fan curves,
// battery, lighting).

extension Mode {
    var short: String {
        switch self {
        case .silent: return "Quiet"
        case .performance: return "All-round"
        case .turbo: return "Max power"
        case .manual: return "Your limits"
        }
    }
    var detail: String {
        switch self {
        case .silent: return "Quiet fans, cool and long battery"
        case .performance: return "Balanced for work and play"
        case .turbo: return "Full power on the charger"
        case .manual: return "Your own power limits"
        }
    }
    var level: Int { self == .silent ? 1 : self == .performance ? 2 : self == .turbo ? 4 : 3 }   // relative power, 4 segments
}

extension View {
    // numbers that refresh every 2 s roll instead of jumping (macOS 14+; plain text before)
    @ViewBuilder func rollingNumber(_ v: Double) -> some View {
        if #available(macOS 14.0, *) { self.contentTransition(.numericText(value: v)) } else { self }
    }
}

enum Fmt {
    static func temp(_ t: Double?) -> String { t.map { String(format: "%.0f°", $0) } ?? "–" }
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? "–" }
}

struct ErrorLine: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(T.amber)   // not red: red already means "selected"
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ---- menu bar panel ------------------------------------------------------------------------------------------------------------
// Same language as the window (dark, chamfered, one red), sized for a glance: temperature leads, then the mode, then the two
// settings people change by hand (charge limit, keyboard light). Setup lives in the window.
// The mode glyph in a small chamfered plate: red with a white glyph when active, raised grey otherwise.
struct ModeBadge: View {
    let mode: Mode, active: Bool, size: CGFloat
    var body: some View {
        Image(systemName: mode.symbol).font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(active ? Color.white : T.dim)
            .frame(width: size, height: size)
            .background(active ? T.red : T.raised, in: Chamfer(cut: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct PopoverTile: View {
    let mode: Mode, selected: Bool, unavailable: Bool, subtitle: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    ModeBadge(mode: mode, active: selected, size: 20)
                    Text(mode.title).font(T.num(11.5)).foregroundStyle(T.text).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                HStack {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(T.dim).lineLimit(1)
                    Spacer(minLength: 4)
                    Segments(lit: mode.level, total: 4, height: 4, color: selected ? T.red : Color.white.opacity(0.4)).frame(width: 34)
                }
            }
            .padding(.horizontal, 10).frame(height: 54)
            .background(selected ? T.red.opacity(0.12) : hover ? T.raised : T.surface, in: Chamfer(cut: 9))
            .overlay(Chamfer(cut: 9).stroke(selected ? T.red : T.line, lineWidth: 1))
            .contentShape(Chamfer(cut: 9))
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .onHover { hover = $0 }
        .accessibilityLabel(mode.title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(unavailable ? "Turbo needs the charger" : mode.detail)
    }
}

struct ContentView: View {
    @ObservedObject var m: RogModel
    let openWindow: (RogDialog?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !m.st.present {
                Label("AsusWmi is not loaded. Controls are off until the kext loads.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
            }
            header
            modes
            VStack(spacing: 0) {
                row("Charge limit") {
                    let opts = [60, 80, 100]
                    Pills(items: opts.map { "\($0)%" }, selected: m.st.charge.flatMap { opts.firstIndex(of: $0) }, minWidth: 30, pad: 7, label: "Charge limit") {
                        m.setCharge(opts[$0])
                    }
                    .disabled(m.st.charge == nil)
                }
                if m.st.lighting {
                    Rectangle().fill(T.line).frame(height: 1)
                    row("Keyboard") {
                        Pills(items: ["Off", "Low", "Med", "High"], selected: m.st.kbd, minWidth: 30, pad: 7, label: "Keyboard") { m.setKbd($0) }
                            .disabled(m.st.kbd == nil)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(T.surface, in: Chamfer(cut: 10))
            .overlay(Chamfer(cut: 10).stroke(T.line))
            .disabled(!m.st.present)
            ErrorLine(text: m.chargeError)
            ErrorLine(text: m.lightingError)
            VStack(spacing: 0) {                        // sound works without AsusWmi
                row("Output") {
                    RogMenu(title: m.sound.output?.label ?? "–", items: m.sound.outputs.map(\.label)) { m.setOutput(m.sound.outputs[$0]) }
                }
                Rectangle().fill(T.line).frame(height: 1)
                row(m.sound.micInUse && m.sound.micMuted != true ? "Microphone · in use" : "Microphone") {
                    Pills(items: ["On", "Muted"], selected: m.sound.micMuted.map { $0 ? 1 : 0 }, minWidth: 30, pad: 7, label: "Microphone") {
                        m.setMicMute($0 == 1)
                    }
                    .disabled(m.sound.micMuted == nil)
                }
            }
            .padding(.horizontal, 12)
            .background(T.surface, in: Chamfer(cut: 10))
            .overlay(Chamfer(cut: 10).stroke(T.line))
            ErrorLine(text: m.soundError)
            footer
        }
        .padding(12).frame(width: 320)
        .background(T.bg)
        .environment(\.colorScheme, .dark)
        .tint(T.red)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(m.tctl.map { String(format: "%.0f", $0) } ?? "–").font(T.num(40)).monospacedDigit()
                        .foregroundStyle((m.tctl ?? 0) >= 90 ? T.red : T.text)
                    Text("°C").font(T.num(14, .medium)).foregroundStyle(T.dim)
                }
                Caps((m.tctl ?? 0) >= 90 ? "CPU · hot" : "CPU")
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Caps("Power"); Spacer()
                    Text(m.watts.map { String(format: "%.0f", $0) } ?? "–").font(T.num(12)).monospacedDigit().foregroundStyle(T.text)
                    Text("W").font(.system(size: 9.5)).foregroundStyle(T.dim)
                }
                fan("CPU fan", m.st.cpuFan)
                fan("GPU fan", m.st.gpuFan)
            }
            .frame(width: 136)
        }
        .padding(12)
        .background(T.surface, in: Chamfer(cut: 12))
        .overlay(Chamfer(cut: 12).stroke(T.line))
        .accessibilityElement(children: .combine)
    }

    func fan(_ name: String, _ rpm: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Caps(name); Spacer()
                Text(verbatim: !m.st.present ? "–" : rpm == 0 ? "Off" : String(rpm)).font(T.num(10.5, .medium)).monospacedDigit().foregroundStyle(T.text)
            }
            Segments(lit: m.st.present ? min(12, rpm * 12 / 6500) : 0, total: 12, height: 4)
        }
    }

    var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Caps("Mode"); Spacer()
                if m.st.present {   // the power source comes from AsusWmi: without it, say nothing
                    Image(systemName: m.st.ac ? "powerplug.fill" : "battery.75percent").font(.system(size: 9.5)).foregroundStyle(T.dim)
                    Text(m.st.ac ? "On charger" : "On battery").font(.system(size: 10.5)).foregroundStyle(T.dim)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Mode.allCases) { mode in
                    let unavailable = mode == .turbo && !m.st.ac
                    let sub = unavailable ? "Needs charger" : (mode == .manual && !m.customReady) ? "Set up…" : mode.short
                    PopoverTile(mode: mode, selected: m.activeMode == mode, unavailable: unavailable, subtitle: sub) {
                        if mode == .manual && !m.customReady { openWindow(.limits) } else { m.choose(mode) }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: m.activeMode)
            .disabled(!m.st.present)
            if let note = m.recentAutoNote {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(T.red)
                    Text(note).font(.system(size: 10.5)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            ErrorLine(text: m.profileError)
        }
    }

    var footer: some View {
        HStack {
            Button { openWindow(nil) } label: {
                HStack(spacing: 6) {
                    Text("Open ROG Control").font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.dim)
                }
                .padding(.horizontal, 10).frame(height: 26)
            }
            .buttonStyle(RogButtonStyle(cut: 6))
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
                Divider()
                Button("Created by thanhnndev (GitHub)") { NSWorkspace.shared.open(URL(string: "https://github.com/thanhnndev")!) }
                Button("Quit ROG Control") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(T.dim)
                    .frame(width: 26, height: 26).background(T.raised, in: Chamfer(cut: 6))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack { Text(title).font(.system(size: 11.5)).foregroundStyle(T.text); Spacer(minLength: 8); control() }.frame(height: 40)
    }
}

// ---- window: ROG look ----------------------------------------------------------------------------------------------------------
// Dark-first, one brand accent (red), amber for warnings, a status color never carries meaning alone.
enum T {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let side = Color(red: 0.063, green: 0.067, blue: 0.078)
    static let surface = Color(red: 0.086, green: 0.094, blue: 0.110)
    static let raised = Color(red: 0.118, green: 0.125, blue: 0.145)
    static let hover = Color(red: 0.150, green: 0.158, blue: 0.180)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.93, green: 0.93, blue: 0.94)
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.60)
    static let faint = Color(red: 0.52, green: 0.54, blue: 0.57)   // 10 pt labels: 4.7:1 on raised, 5.1:1 on surface (WCAG AA 4.5:1)
    static let red = Color(red: 1.0, green: 0.13, blue: 0.24)        // strokes, segments, text on dark (5.2:1 on bg)
    static let redFill = Color(red: 0.86, green: 0.10, blue: 0.20)   // behind white text: 5.0:1 (T.red gives 3.8:1)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.20)
    static let nsBG = NSColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)
    static func num(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w).width(.expanded) }
}
struct Caps: View {      // small tracked label, the HUD voice of the window
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(T.faint) }
}

// Sharp card with the top-right corner cut
struct Chamfer: Shape {
    var cut: CGFloat = 14
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p
    }
}
struct Card<C: View>: View {
    var cut: CGFloat = 14, pad: CGFloat = 18, active = false, stretch = false
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(pad).frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .background(active ? T.red.opacity(0.10) : T.surface, in: Chamfer(cut: cut))
            .overlay(Chamfer(cut: cut).stroke(active ? T.red : T.line, lineWidth: 1))
    }
}

// The Slash bar's slanted LED segments
struct Slant: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.height * 0.45, r.width * 0.35)   // tall cells keep a gentle slant
        var p = Path(); p.move(to: CGPoint(x: r.minX + k, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p
    }
}
struct Segments: View {
    let lit: Int, total: Int
    var height: CGFloat = 10, color: Color = T.red
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in Slant().fill(i < lit ? color : Color.white.opacity(0.08)).frame(height: height) }
        }
        .animation(.easeOut(duration: 0.25), value: lit)
    }
}

struct Gauge: View {
    let value: Double, maximum: Double, text: String, unit: String, caption: String, size: CGFloat
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: size * 0.045))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * min(1, max(0, value / maximum))).stroke(T.red, style: StrokeStyle(lineWidth: size * 0.045))
                .rotationEffect(.degrees(135))
                .animation(.easeInOut(duration: 0.8), value: value)
            ForEach(0..<16, id: \.self) { i in
                Rectangle().fill(Color.white.opacity(i % 5 == 0 ? 0.30 : 0.12)).frame(width: 1, height: i % 5 == 0 ? 7 : 4)
                    .offset(y: -size / 2 + size * 0.09).rotationEffect(.degrees(-135 + Double(i) * 18))
            }
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(text).font(T.num(size * 0.24)).monospacedDigit().foregroundStyle(T.text)
                    Text(unit).font(T.num(size * 0.09, .medium)).foregroundStyle(T.dim)
                }
                Caps(caption)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption).accessibilityValue("\(text) \(unit)")
    }
}

// Chamfered button: pills, preset cards and the menu triggers share it
struct RogButtonStyle: ButtonStyle {
    var selected = false, prominent = false, cut: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View { Chip(configuration: configuration, selected: selected, prominent: prominent, cut: cut) }
    struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool, prominent: Bool, cut: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let filled = selected || prominent
            configuration.label
                .foregroundStyle(filled ? Color.white : (enabled ? T.text : T.faint))
                .background(filled ? T.redFill.opacity(configuration.isPressed ? 0.8 : 1) : (configuration.isPressed ? T.hover : hover && enabled ? T.hover : T.raised),
                            in: Chamfer(cut: cut))
                .contentShape(Chamfer(cut: cut))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct Pills: View {
    let items: [String]
    let selected: Int?
    var minWidth: CGFloat = 34
    var pad: CGFloat = 8
    var label = ""
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(items[i]).font(.system(size: 11.5, weight: i == selected ? .semibold : .regular))
                        .fixedSize().frame(minWidth: minWidth).padding(.horizontal, pad).frame(height: 26)
                }
                .buttonStyle(RogButtonStyle(selected: i == selected, cut: 5))
                .accessibilityLabel("\(label) \(items[i])").accessibilityAddTraits(i == selected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct RogMenu: View {
    let title: String
    let items: [String]
    let pick: (Int) -> Void
    var body: some View {
        Menu {
            ForEach(items.indices, id: \.self) { i in Button(items[i]) { pick(i) } }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(T.text).padding(.horizontal, 10).frame(height: 26)
            .background(T.raised, in: Chamfer(cut: 6))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct RogSlider: View {
    let name: String
    @Binding var value: Int
    let range: (Int, Int)
    var body: some View {
        let lo = range.0, hi = max(range.1, range.0 + 1)
        GeometryReader { g in
            let f = CGFloat(min(max(value, lo), hi) - lo) / CGFloat(hi - lo)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 3)
                Rectangle().fill(T.red).frame(width: g.size.width * f, height: 3)
                Rectangle().fill(T.text).frame(width: 4, height: 16).offset(x: max(0, g.size.width * f - 2))
            }
            .frame(height: 20).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let x = min(max(0, v.location.x), g.size.width)
                value = lo + Int((x / max(1, g.size.width) * CGFloat(hi - lo)).rounded())
            })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(name).accessibilityValue("\(value) watts")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(hi, value + 1)
            case .decrement: value = max(lo, value - 1)
            @unknown default: break
            }
        }
    }
}

struct FanCurvePoint: Identifiable {
    let id: Int
    let temperature: Int
    let duty: Int
    let segment: Int
}
struct FanCurveData {
    let points: [FanCurvePoint]
    let omitted: Int
    init(_ bytes: [UInt8]) {
        guard bytes.count == 16 else { points = []; omitted = bytes.count == 0 ? 0 : 8; return }
        var valid: [FanCurvePoint] = []
        var skipped = 0, segment = 0
        var previous: Int?
        for i in 0..<8 {
            let temperature = Int(bytes[i]), duty = Int(bytes[8 + i])
            guard (20...105).contains(temperature), (0...100).contains(duty),
                  previous == nil || temperature >= previous! else {
                skipped += 1; segment += 1; continue
            }
            valid.append(FanCurvePoint(id: i, temperature: temperature, duty: duty, segment: segment))
            previous = temperature
        }
        points = valid; omitted = skipped
    }
}

// Firmware fan curve, drawn in the window's style. Hover reads a point.
struct CurveChart: View {
    let c: [UInt8]
    @State private var hovered: Int?
    private var data: FanCurveData { FanCurveData(c) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if data.points.isEmpty {
                Text("The firmware did not return a usable fan curve.").font(.system(size: 12)).foregroundStyle(T.dim).frame(height: 120)
            } else {
                Chart(data.points) { p in
                    AreaMark(x: .value("Temperature", p.temperature), y: .value("Fan duty", p.duty), series: .value("Segment", p.segment))
                        .foregroundStyle(LinearGradient(colors: [T.red.opacity(0.22), T.red.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Temperature", p.temperature), y: .value("Fan duty", p.duty), series: .value("Segment", p.segment))
                        .foregroundStyle(T.red).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Temperature", p.temperature), y: .value("Fan duty", p.duty))
                        .symbolSize(p.id == hovered ? 70 : 26).foregroundStyle(T.text)
                }
                .chartXScale(domain: 20...105).chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: [20, 40, 60, 80, 100]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)°").foregroundStyle(T.faint) } } } }
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").foregroundStyle(T.faint) } } } }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let origin = geometry[proxy.plotAreaFrame].origin
                                    let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                                    hovered = data.points.min { distance($0, local, proxy) < distance($1, local, proxy) }?.id
                                case .ended: hovered = nil
                                }
                            }
                    }
                }
                .frame(height: 180)
            }
            HStack {
                if data.omitted > 0 {
                    Text("\(data.omitted) firmware point(s) outside the valid range are not drawn.").font(.system(size: 11)).foregroundStyle(T.dim)
                }
                Spacer()
                if let p = data.points.first(where: { $0.id == hovered }) {
                    Text("\(p.temperature)°C · \(p.duty)%").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(T.text)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fan duty by temperature")
        .accessibilityValue(data.points.map { "\($0.temperature) degrees, \($0.duty) percent" }.joined(separator: "; "))
    }
    private func distance(_ p: FanCurvePoint, _ pos: CGPoint, _ proxy: ChartProxy) -> CGFloat {
        guard let x = proxy.position(forX: p.temperature), let y = proxy.position(forY: p.duty) else { return .infinity }
        return pow(x - pos.x, 2) + pow(y - pos.y, 2)
    }
}

struct LiveChart: View {
    let samples: [RogModel.Sample]
    var height: CGFloat = 96
    var body: some View {
        if samples.count < 2 {
            Text("Collecting readings…").font(.system(size: 11)).foregroundStyle(T.dim).frame(maxWidth: .infinity, minHeight: height)
        } else {
            Chart {
                ForEach(samples) { s in
                    AreaMark(x: .value("Time", s.date), yStart: .value("Base", 30), yEnd: .value("CPU", s.temp))
                        .foregroundStyle(LinearGradient(colors: [T.red.opacity(0.28), T.red.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.date), y: .value("CPU", s.temp), series: .value("Series", "temp"))
                        .foregroundStyle(T.red).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.monotone)
                }
                ForEach(samples.filter { $0.watts != nil }) { s in
                    // power on the same axis: 0..70 W drawn as 30..100
                    LineMark(x: .value("Time", s.date), y: .value("Power", min(100, 30 + (s.watts ?? 0))), series: .value("Series", "watts"))
                        .foregroundStyle(Color.white.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 30...100).chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: [40, 70, 100]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)°").font(.system(size: 10)).foregroundStyle(T.faint) } } } }
            .frame(height: height)
            .accessibilityLabel("CPU temperature and package power, last minutes")
        }
    }
}

// One screen, NitroSense style: live readings and the mode on top, three tiles below with their everyday control inline.
// Anything that is set up once (Custom limits, fan curves, Slash animations, battery details, settings) opens as a dialog over
// the screen instead of a page behind a side menu.
enum RogDialog: String, Identifiable {
    case limits, fans, slash, battery, settings, doctor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .limits: return "Custom limits"
        case .fans: return "Fan curves"
        case .slash: return "Slash animations"
        case .battery: return "Battery"
        case .settings: return "Settings"
        case .doctor: return "Doctor"
        }
    }
    var width: CGFloat { self == .limits ? 820 : self == .slash ? 900 : self == .settings ? 560 : self == .doctor ? 760 : 680 }
}

struct TileHead: View {           // tile title, with an opener for its dialog on the right
    let title: String
    var action: String? = nil
    var open: () -> Void = {}
    var body: some View {
        HStack {
            Caps(title); Spacer()
            if let a = action {
                Button(action: open) {
                    HStack(spacing: 4) {
                        Text(a).font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(T.dim).padding(.horizontal, 8).frame(height: 22)
                }
                .buttonStyle(RogButtonStyle(cut: 5))
                .accessibilityLabel("\(title): \(a)")
            }
        }
    }
}

struct RogWindowView: View {
    static let column: CGFloat = (1120 - 36 - 24) / 3          // window width less the side padding and two 12 pt gaps
    @ObservedObject var m: RogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                HStack(alignment: .top, spacing: 12) {
                    LiveCard(m: m)
                    ModeCard(m: m).frame(width: 350)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    BatteryTile(m: m)
                    LimitsTile(m: m)
                    LightingTile(m: m)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!m.st.present)
            HStack(alignment: .top, spacing: 12) {      // sound and camera do not need AsusWmi
                SoundTile(m: m).frame(width: Self.column * 2 + 12)   // on the 3-column grid of the row above
                MicCameraTile(m: m)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
        .frame(width: 1120, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, -27)              // pull the header up into the 28 pt title bar, level with the traffic lights
        .background(T.bg.ignoresSafeArea())
        .overlay {
            if let d = m.dialog {
                DialogShell(kind: d, m: m) { m.dialog = nil }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: m.dialog)
        .environment(\.colorScheme, .dark)
        .tint(T.red)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 10) {     // sits in the title bar, centred on the traffic lights
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("ROG CONTROL").font(T.num(16, .bold)).foregroundStyle(T.text)
                Caps("Zephyrus G14 · GA403WM")
            }
            .padding(.leading, 68)        // clear the traffic lights
            Spacer()
            chip(dot: m.st.present ? .green : T.amber, m.st.present ? "AsusWmi connected" : "AsusWmi not loaded, controls are off until it loads through OpenCore")
            if m.st.present { chip(icon: m.st.ac ? "powerplug.fill" : "battery.75percent", m.st.ac ? "On charger" : "On battery") }
            doctorButton
            Button { m.dialog = .settings } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(T.dim).frame(width: 28, height: 26)
            }
            .buttonStyle(RogButtonStyle(cut: 6)).help("Settings").accessibilityLabel("Settings")
        }
        .frame(height: 28)
    }
    // Doctor: the worst result colours the icon, and the count of problems is spelled out next to it
    var doctorButton: some View {
        let issues = m.doctor.filter { $0.level >= .warn }
        let worst = m.doctor.map(\.level).max() ?? .ok
        return Button { m.runDoctor(); m.dialog = .doctor } label: {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope").font(.system(size: 11, weight: .semibold)).foregroundStyle(worst.color)
                Text(m.doctor.isEmpty ? "Doctor" : issues.isEmpty ? "All good" : "\(issues.count) to fix").font(.system(size: 11))
                    .foregroundStyle(issues.isEmpty ? T.dim : T.text)
            }
            .padding(.horizontal, 10).frame(height: 26)
        }
        .buttonStyle(RogButtonStyle(cut: 6)).help("Doctor: checks the drivers, Fn keys, audio and permissions")
        .accessibilityLabel("Doctor").accessibilityValue(issues.isEmpty ? "No problems" : "\(issues.count) problems")
    }
    func chip(dot: Color? = nil, icon: String? = nil, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let d = dot { Circle().fill(d).frame(width: 6, height: 6) }
            if let i = icon { Image(systemName: i).font(.system(size: 10)).foregroundStyle(T.dim) }
            Text(text).font(.system(size: 11)).foregroundStyle(T.dim)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(T.surface, in: Chamfer(cut: 6)).overlay(Chamfer(cut: 6).stroke(T.line))
    }
}

// ---- top row ---------------------------------------------------------------------------------------------------------------------
struct LiveCard: View {
    @ObservedObject var m: RogModel
    var limitNow: Int { m.st.ppt[2] > 0 ? m.st.ppt[2] : 0 }
    var body: some View {
        Card(pad: 16, stretch: true) {
            HStack(alignment: .center, spacing: 20) {
                Gauge(value: m.tctl ?? 0, maximum: 100, text: m.tctl.map { String(format: "%.0f", $0) } ?? "–", unit: "°C", caption: "CPU", size: 150)
                Gauge(value: m.watts ?? 0, maximum: Double(limitNow > 0 ? limitNow : 80),
                      text: m.watts.map { String(format: "%.0f", $0) } ?? "–", unit: "W", caption: "Package", size: 108)
                VStack(alignment: .leading, spacing: 13) {
                    fan("CPU fan", m.st.cpuFan)
                    fan("GPU fan", m.st.gpuFan)
                    HStack(spacing: 18) {
                        stat("Power limit", limitNow > 0 ? "\(limitNow) W" : "Profile")
                        stat("GPU", gpuMode)
                        stat("TGP", m.st.baseTgp > 0 ? "\(m.st.baseTgp) W" : "–")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if (m.tctl ?? 0) >= 90 {
                Label("Running hot. Silent lowers power and heat.", systemImage: "thermometer.high").font(.system(size: 11)).foregroundStyle(T.amber)
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Caps(historyCaption); Spacer()
                    legend(T.red, "Temperature", dashed: false)
                    legend(Color.white.opacity(0.55), "Power", dashed: true)
                }
                LiveChart(samples: m.history, height: 150)
            }
            .padding(.top, 10)
        }
    }
    var historyCaption: String {
        guard let first = m.history.first?.date else { return "Live" }
        let minutes = max(1, Int(Date().timeIntervalSince(first) / 60))
        return "Last \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
    var gpuMode: String {
        let mux = m.st.gpuMux
        if mux == ~0 { return "–" }
        var s = mux & 1 == 0 ? "dGPU only" : "Hybrid"
        if m.st.dgpu != ~0 && m.st.dgpu & 1 != 0 { s += ", off" }
        return s
    }
    func fan(_ name: String, _ rpm: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Caps(name); Spacer()
                Text(verbatim: m.st.present ? String(rpm) : "–").font(T.num(14)).monospacedDigit().foregroundStyle(T.text)
                Text("rpm").font(.system(size: 10)).foregroundStyle(T.dim)
            }
            Segments(lit: m.st.present ? min(20, rpm * 20 / 6500) : 0, total: 20, height: 8)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityValue("\(rpm) rpm")
    }
    func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Caps(k); Text(v).font(T.num(12.5, .medium)).foregroundStyle(T.text).lineLimit(1) }
    }
    func legend(_ c: Color, _ s: String, dashed: Bool) -> some View {
        HStack(spacing: 5) { Rectangle().fill(c).frame(width: 12, height: dashed ? 1 : 2); Text(s).font(.system(size: 10)).foregroundStyle(T.dim) }
    }
}

struct ModeCard: View {
    @ObservedObject var m: RogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Card(pad: 14, stretch: true) {
            TileHead(title: "Mode")
            VStack(spacing: 6) {
                ForEach(Mode.allCases) { mode in row(mode) }
            }
            .padding(.top, 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: m.activeMode)
            ErrorLine(text: m.profileError).padding(.top, 6)
            Rectangle().fill(T.line).frame(height: 1).padding(.vertical, 12)
            Caps("Switch automatically")
            VStack(spacing: 8) { sourceRow(ac: true); sourceRow(ac: false) }.padding(.top, 8)
        }
    }
    func row(_ mode: Mode) -> some View {
        let on = m.activeMode == mode
        let unavailable = mode == .turbo && !m.st.ac
        let desc = unavailable ? "Needs the charger" :
            mode == .manual ? (m.customReady ? "\(m.settings.spl) / \(m.settings.sppt) / \(m.settings.fppt) W, your limits" : "Set up your own limits")
            : mode.detail
        return Button {
            if mode == .manual && !m.customReady { m.dialog = .limits } else { m.choose(mode) }
        } label: {
            HStack(spacing: 10) {
                ModeBadge(mode: mode, active: on, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title).font(T.num(12.5)).foregroundStyle(T.text)
                    Text(desc).font(.system(size: 10.5)).foregroundStyle(T.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                Segments(lit: mode.level, total: 4, height: 5, color: on ? T.red : Color.white.opacity(0.4)).frame(width: 40)
            }
            .padding(.horizontal, 10).frame(height: 46)
            .background(on ? T.red.opacity(0.12) : T.raised.opacity(0.6), in: Chamfer(cut: 8))
            .overlay(Chamfer(cut: 8).stroke(on ? T.red : Color.clear))
            .contentShape(Chamfer(cut: 8))
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.45 : 1)
        .accessibilityLabel(mode.title).accessibilityHint(desc).accessibilityAddTraits(on ? .isSelected : [])
    }
    func sourceRow(ac: Bool) -> some View {
        let current = m.st.ac == ac
        let choices: [Mode] = ac ? Mode.allCases : [.silent, .performance, .manual]
        return HStack(spacing: 8) {
            Image(systemName: ac ? "powerplug.fill" : "battery.75percent").font(.system(size: 11)).foregroundStyle(current ? T.text : T.dim).frame(width: 16)
            Text(ac ? "On charger" : "On battery").font(.system(size: 12)).foregroundStyle(current ? T.text : T.dim)
            if current { Text("NOW").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(T.red) }
            Spacer()
            RogMenu(title: m.mode(forAC: ac).title, items: choices.map(\.title)) { m.setMode(choices[$0], forAC: ac) }
        }
    }
}

// ---- bottom row ------------------------------------------------------------------------------------------------------------------
extension RogModel {
    var batteryLevel: Int? { st.batFull > 0 ? min(100, max(0, st.batNow * 100 / st.batFull)) : nil }
    var batteryState: String {
        guard st.present else { return "" }
        let limit = st.charge.map { " at \($0)%" } ?? ""
        if st.batState & 2 != 0 { return "Charging" + (st.batRate > 0 ? ", \(st.batRate) mA" : "") }
        if st.batState & 1 != 0 { return "On battery" + (st.batRate > 0 ? ", \(st.batRate) mA" : "") }
        return st.ac ? "Holding\(limit)" : "On battery"
    }
}

struct BatteryTile: View {
    @ObservedObject var m: RogModel
    let presets = [60, 80, 100]
    var body: some View {
        Card(pad: 14, stretch: true) {
            TileHead(title: "Battery", action: "Details") { m.dialog = .battery }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: m.batteryLevel.map(String.init) ?? "–").font(T.num(34)).monospacedDigit().foregroundStyle(T.text)
                Text("%").font(T.num(14, .medium)).foregroundStyle(T.dim)
                Spacer()
                Text(m.batteryState).font(.system(size: 11)).foregroundStyle(T.dim)
            }
            .padding(.top, 8)
            Segments(lit: (m.batteryLevel ?? 0) * 20 / 100, total: 20, height: 10).padding(.top, 4)
            Spacer(minLength: 14)
            HStack {
                Text("Charge limit").font(.system(size: 12)).foregroundStyle(T.text); Spacer()
                Pills(items: presets.map { "\($0)%" }, selected: m.st.charge.flatMap { presets.firstIndex(of: $0) }, minWidth: 30, pad: 7,
                      label: "Charge limit") { m.setCharge(presets[$0]) }
                    .disabled(m.st.charge == nil)
            }
            ErrorLine(text: m.chargeError).padding(.top, 6)
        }
    }
}

struct LimitsTile: View {
    @ObservedObject var m: RogModel
    var body: some View {
        Card(pad: 14, stretch: true) {
            TileHead(title: "Custom limits", action: "Edit") { m.dialog = .limits }
            let top = Double(max(m.settings.fppt, m.settings.sppt, m.settings.spl, 1))
            HStack(alignment: .bottom, spacing: 8) {
                bar("Burst", m.settings.fppt, top, 0.95)
                bar("Boost", m.settings.sppt, top, 0.65)
                bar("Sustained", m.settings.spl, top, 0.40)
            }
            .frame(height: 64).padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Custom limits: burst \(m.settings.fppt), short boost \(m.settings.sppt), sustained \(m.settings.spl) watts")
            Spacer(minLength: 12)
            HStack {
                Text("Fans follow").font(.system(size: 12)).foregroundStyle(T.text); Spacer()
                Button { m.dialog = .fans } label: {
                    HStack(spacing: 5) {
                        Text("\(m.settings.fanBase.title) curve").font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 10))
                    }
                    .padding(.horizontal, 9).frame(height: 26)
                }
                .buttonStyle(RogButtonStyle(cut: 6)).help("Show the fan curves")
            }
        }
    }
    func bar(_ name: String, _ w: Int, _ top: Double, _ a: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(w) W").font(T.num(11)).foregroundStyle(T.text)
            Rectangle().fill(T.red.opacity(a)).frame(height: max(3, CGFloat(Double(w) / top) * 26))
            Text(name).font(.system(size: 10)).foregroundStyle(T.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LightingTile: View {
    static let auraModes = ["Static", "Breathe", "Strobe"]       // the single-color keyboard's modes (AsusWmi kAuraModes)
    @ObservedObject var m: RogModel
    var slash: Slash { m.currentSlash }
    var body: some View {
        Card(pad: 14, stretch: true) {
            if !m.st.lighting {
                TileHead(title: "Lighting")
                Text("Lighting needs AsusWmi ABI 3 and the N-KEY keyboard.").font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 10)
            } else {
                TileHead(title: "Lighting", action: "Animations") { m.dialog = .slash }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Caps("Slash")
                        Text(slash.bright > 0 ? Slash.modes[min(slash.mode, Slash.modes.count - 1)] : "Off").font(T.num(18)).foregroundStyle(T.text)
                    }
                    Spacer()
                    Toggle("Slash", isOn: slashOn(m)).toggleStyle(.switch).labelsHidden().tint(T.red)
                }
                .padding(.top, 8)
                Spacer(minLength: 10)
                HStack {
                    Text("Brightness").font(.system(size: 12)).foregroundStyle(T.text); Spacer()
                    Pills(items: ["Low", "Med", "High"], selected: max(1, slash.bright) - 1, minWidth: 30, pad: 7, label: "Slash brightness") {
                        var s = slash; s.bright = $0 + 1; m.setSlash(s)
                    }
                    .disabled(slash.bright == 0).opacity(slash.bright == 0 ? 0.5 : 1)
                }
                HStack {
                    Text("Keyboard").font(.system(size: 12)).foregroundStyle(T.text); Spacer()
                    Pills(items: ["Off", "Low", "Med", "High"], selected: m.st.kbd, minWidth: 28, pad: 6, label: "Keyboard") { m.setKbd($0) }
                        .disabled(m.st.kbd == nil)
                        .help("Fn+F2 and Fn+F3 change it too")
                }
                .padding(.top, 8)
                HStack {
                    Text("Aura").font(.system(size: 12)).foregroundStyle(T.text); Spacer()
                    Pills(items: Self.auraModes, selected: m.st.aura, minWidth: 28, pad: 6, label: "Aura mode") { m.setAura($0) }
                        .disabled(!m.st.hasAura)
                        .help(m.st.hasAura ? "Fn+F4 steps through them too" : "Needs AsusWmi 0.2.2 (ABI 5): restart after installing it")
                }
                .padding(.top, 8)
                ErrorLine(text: m.lightingError).padding(.top, 6)
            }
        }
    }
}

// a brightness of 0 is "off"; the last brightness is kept so switching back on restores it
@MainActor func slashOn(_ m: RogModel) -> Binding<Bool> {
    Binding(get: { m.currentSlash.bright > 0 }, set: { on in
        var s = m.currentSlash
        s.bright = on ? (UserDefaults.standard.object(forKey: "slash.on.bright") as? Int ?? 2) : 0
        if !on { UserDefaults.standard.set(m.currentSlash.bright, forKey: "slash.on.bright") }
        m.setSlash(s)
    })
}


// ---- sound, mic and camera row ---------------------------------------------------------------------------------------------------
extension SoundState {
    var outputLine: String {
        guard let o = output else { return "No output device" }
        if o.isRogSpeakers { return !daemon ? "rogaudiod stopped, no sound" : chain ? "Sound profile on" : "Starting the profile" }
        if o.builtin { return rog ? "Playing, no profile" : "RogAudio not installed" }
        return "Playing, no profile"
    }
    var outputWarn: Bool { output?.isRogSpeakers == true && !daemon }
}

struct SoundTile: View {
    @ObservedObject var m: RogModel
    var s: SoundState { m.sound }
    static let profiles: [(name: String, icon: String)] = [("Off", "circle.slash"), ("Balanced", "slider.horizontal.3"),
                                                          ("Movie", "film"), ("Music", "music.note"), ("Voice", "person.wave.2")]
    // ROG Speakers and Built-in always get a card; one more card for the active (or first) other device, the rest go in a menu
    var cards: [AudioDevice] {
        let rank: (AudioDevice) -> Int = { $0.isRogSpeakers ? 0 : $0.builtin ? 1 : 2 }
        let sorted = s.outputs.sorted { rank($0) < rank($1) }
        var c = sorted.filter { rank($0) < 2 }
        let others = sorted.filter { rank($0) == 2 }
        if let o = others.first(where: { $0.id == s.output?.id }) ?? others.first { c.append(o) }
        return c
    }
    var more: [AudioDevice] { s.outputs.filter { d in !cards.contains { $0.id == d.id } } }
    var body: some View {
        Card(pad: 14, stretch: true) {
            TileHead(title: "Sound output")
            HStack(spacing: 8) {
                ForEach(cards) { d in OutputCard(d: d, on: d.id == s.output?.id, s: s) { m.setOutput(d) } }
                if !more.isEmpty {
                    RogMenu(title: "More", items: more.map(\.label)) { m.setOutput(more[$0]) }
                        .help("Other output devices")
                }
            }
            .padding(.top, 10)
            if s.outputs.isEmpty { Text("No output device").font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 10) }
            Spacer(minLength: 14)
            HStack {
                Caps("Sound profile"); Spacer()
                if s.output?.isRogSpeakers != true && s.rog {
                    Text("Applies to ROG Speakers").font(.system(size: 10.5)).foregroundStyle(T.faint)
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.profiles.indices, id: \.self) { i in
                    let p = Self.profiles[i], on = Sound.profiles.firstIndex(of: s.profile) == i
                    Button { m.setProfile(Sound.profiles[i]) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.icon).font(.system(size: 11, weight: .semibold))
                            Text(p.name).font(.system(size: 12, weight: on ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity).frame(height: 32)
                    }
                    .buttonStyle(RogButtonStyle(selected: on, cut: 6))
                    .accessibilityLabel("Sound profile \(p.name)").accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.top, 8)
            .disabled(!s.rog).opacity(s.rog ? 1 : 0.5)
            .animation(.easeOut(duration: 0.15), value: s.profile)
            ErrorLine(text: m.soundError).padding(.top, 6)
        }
    }
}

// One output device: icon, name and what it does; the active one shows the live status instead, red-outlined like the mode rows
struct OutputCard: View {
    let d: AudioDevice, on: Bool, s: SoundState
    let pick: () -> Void
    @State private var hover = false
    var icon: String { d.isRogSpeakers ? "hifispeaker.2.fill" : d.builtin ? "laptopcomputer" : "speaker.wave.2.fill" }
    var name: String { d.isRogSpeakers ? "ROG Speakers" : d.builtin ? "Built-in" : d.name }
    var note: String {
        if on { return s.outputLine }
        return d.isRogSpeakers ? "With sound profile" : d.builtin ? "Direct, no profile" : "External"
    }
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(on ? T.red : T.dim).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle)
                    Text(note).font(.system(size: 10.5)).foregroundStyle(on && s.outputWarn ? T.amber : T.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 50)
            .background(on ? T.red.opacity(0.10) : hover ? T.hover : T.raised, in: Chamfer(cut: 8))
            .overlay(Chamfer(cut: 8).stroke(on ? T.red : Color.clear, lineWidth: 1))
            .contentShape(Chamfer(cut: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(d.isRogSpeakers ? "ROG Speakers runs the sound profile" : d.builtin ? "Built-in plays without the profile" : d.name)
        .accessibilityLabel("Output \(name)").accessibilityValue(note).accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct MicCameraTile: View {
    @ObservedObject var m: RogModel
    var s: SoundState { m.sound }
    var body: some View {
        Card(pad: 14, stretch: true) {
            HStack(spacing: 10) {                     // each half carries its own label, so the tile has no title
                state("Microphone", s.micMuted == nil ? "Not found" : s.micMuted == true ? "Muted" : s.micInUse ? "In use" : "Ready",
                      live: s.micInUse && s.micMuted != true)
                Spacer()
                Pills(items: ["On", "Muted"], selected: s.micMuted.map { $0 ? 1 : 0 }, minWidth: 34, pad: 7, label: "Microphone") {
                    m.setMicMute($0 == 1)
                }
                .disabled(s.micMuted == nil)
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clear Mic").font(.system(size: 12)).foregroundStyle(T.text)
                    Text(s.rog ? "Noise reduction, apps record from ROG Clear Mic" : "Needs RogAudio").font(.system(size: 10.5)).foregroundStyle(T.dim)
                }
                Spacer()
                Toggle("Clear Mic", isOn: Binding(get: { s.clearMic }, set: { m.setClearMic($0) })).toggleStyle(.switch).labelsHidden().tint(T.red)
                    .disabled(!s.rog)
            }
            .padding(.top, 8)
            Rectangle().fill(T.line).frame(height: 1).padding(.vertical, 10)
            HStack {
                state("Camera", s.camera == nil ? "Not found" : s.cameraInUse ? "In use" : "Off", live: s.cameraInUse)
                Spacer()
                Text(s.camera ?? "").font(.system(size: 11)).foregroundStyle(T.dim).lineLimit(1)
            }
            .help("The firmware has no camera switch; macOS shows which app uses it in Control Center")
        }
    }
    // a red dot marks live capture; the word says it too, so the colour never carries it alone
    func state(_ title: String, _ value: String, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caps(title)
            HStack(spacing: 6) {
                if live { Circle().fill(T.red).frame(width: 7, height: 7) }
                Text(value).font(T.num(15)).foregroundStyle(T.text)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// ---- dialogs ---------------------------------------------------------------------------------------------------------------------
// Dims the screen and shows one chamfered sheet. The close button, Esc and a click on the dim area close it.
struct DialogShell: View {
    let kind: RogDialog
    @ObservedObject var m: RogModel
    let close: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).contentShape(Rectangle()).onTapGesture(perform: close).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(kind.title).font(T.num(16)).foregroundStyle(T.text)
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(T.dim).frame(width: 26, height: 26)
                    }
                    .buttonStyle(RogButtonStyle(cut: 6))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }
                .padding(.bottom, 16)
                Group {
                    switch kind {
                    case .limits: LimitsEditor(m: m)
                    case .fans: FanCurves(m: m)
                    case .slash: SlashEditor(m: m)
                    case .battery: BatteryDetails(m: m)
                    case .settings: SettingsEditor(m: m)
                    case .doctor: DoctorView(m: m)
                    }
                }
                .disabled(!m.st.present && kind != .settings && kind != .doctor)
            }
            .padding(20).frame(width: kind.width)
            .background(T.surface, in: Chamfer(cut: 16)).overlay(Chamfer(cut: 16).stroke(T.line))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

struct LimitsEditor: View {
    @ObservedObject var m: RogModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Caps("Custom mode, \(m.st.ac ? "on charger" : "on battery")")
                    limit("Burst", "A few seconds when a load starts", "FPPT", $m.settings.fppt, m.st.ranges[2])
                    limit("Short boost", "The first few minutes", "SPPT", $m.settings.sppt, m.st.ranges[1])
                    limit("Sustained", "As long as the load lasts", "SPL", $m.settings.spl, m.st.ranges[0])
                    HStack(spacing: 10) {
                        Caps("Fans follow")
                        Spacer()
                        let bases: [Mode] = [.silent, .performance, .turbo]
                        RogMenu(title: m.settings.fanBase.title + " curve", items: bases.map { $0.title + " curve" }) {
                            m.settings.fanBase = bases[$0]; m.loadCurve()
                        }
                    }
                }
                .frame(width: 380)
                VStack(alignment: .leading, spacing: 10) {
                    Caps("How the CPU uses them")
                    envelope
                    Text("Higher limits are faster but louder and hotter. ROG Control keeps them in order and within the firmware range for this power source.")
                        .font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if m.manualDirty {
                    Image(systemName: "circle.dashed").font(.system(size: 11, weight: .bold)).foregroundStyle(T.amber)
                    Text("Not saved").font(.system(size: 12)).foregroundStyle(T.amber)
                } else {
                    Image(systemName: m.customReady ? "checkmark" : "circle").font(.system(size: 11, weight: .bold)).foregroundStyle(T.dim)
                    Text(m.activeMode == .manual ? "Saved and in use" : m.customReady ? "Saved. Choose Custom to use it." : "Not set up yet")
                        .font(.system(size: 12)).foregroundStyle(T.dim)
                }
                Spacer()
                Button { m.resetCustom() } label: { Text("Reset").font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).frame(height: 30) }
                    .buttonStyle(RogButtonStyle(cut: 7)).disabled(!m.manualDirty)
                Button { m.saveCustom() } label: { Text("Save to Custom").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).frame(height: 30) }
                    .buttonStyle(RogButtonStyle(prominent: true, cut: 7)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
            ErrorLine(text: m.profileError).padding(.top, 8)
        }
    }
    func limit(_ name: String, _ desc: String, _ code: String, _ v: Binding<Int>, _ range: (Int, Int)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(T.text)
                Text(code).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(T.faint)
                Spacer()
                Text(verbatim: String(v.wrappedValue)).font(T.num(18)).monospacedDigit().foregroundStyle(T.text)
                Text("W").font(.system(size: 11)).foregroundStyle(T.dim)
            }
            RogSlider(name: name, value: v, range: range)
            Text("\(desc) · \(range.0) to \(range.1) W").font(.system(size: 11)).foregroundStyle(T.dim)
        }
    }
    // Burst, short boost and sustained as one picture: height is the limit, width is roughly how long it lasts
    var envelope: some View {
        let top = Double(max(m.settings.fppt, m.settings.sppt, m.settings.spl, 1))
        let blocks: [(String, String, Int, CGFloat, Double)] = [("Burst", "seconds", m.settings.fppt, 0.16, 0.95),
                                                                ("Short boost", "minutes", m.settings.sppt, 0.32, 0.65),
                                                                ("Sustained", "as long as needed", m.settings.spl, 0.52, 0.40)]
        return GeometryReader { g in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(blocks.indices, id: \.self) { i in
                    let b = blocks[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(b.2) W").font(T.num(12)).foregroundStyle(T.text)
                        Rectangle().fill(T.red.opacity(b.4)).frame(height: max(4, (g.size.height - 46) * CGFloat(Double(b.2) / top)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.0).font(.system(size: 11, weight: .medium)).foregroundStyle(T.text)
                            Text(b.1).font(.system(size: 10)).foregroundStyle(T.dim)
                        }
                        .frame(height: 26, alignment: .topLeading)
                    }
                    .frame(width: (g.size.width - 4) * b.3)
                }
            }
            .animation(.easeOut(duration: 0.15), value: m.settings.fppt + m.settings.sppt * 100 + m.settings.spl * 10000)
        }
        .frame(height: 210).padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burst \(m.settings.fppt) watts for seconds, short boost \(m.settings.sppt) watts for minutes, sustained \(m.settings.spl) watts")
    }
}

struct FanCurves: View {
    @ObservedObject var m: RogModel
    @State private var fan = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caps("\(m.curveMode.title) mode")
                Spacer()
                Pills(items: ["CPU", "GPU"], selected: fan, minWidth: 40, label: "Fan") { fan = $0 }
            }
            Group {
                if let bytes = fan == 0 ? m.curve : m.gpuCurve { CurveChart(c: bytes) }
                else { Text("The firmware did not return a fan curve.").font(.system(size: 12)).foregroundStyle(T.dim).frame(height: 120) }
            }
            .padding(.top, 10)
            Text("Read from the firmware: fan speed by temperature. A reference, not live fan speed.")
                .font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 6)
        }
    }
}

// A drawn G14 lid with the Slash strip playing the chosen mode. The animations are approximations of the firmware's: the lid
// itself plays the real one. Hovering a mode in the grid previews it here before it is applied.
enum SlashAnim {
    static let count = 7                        // slanted LED segments drawn along the strip
    // brightness 0...1 of segment i at time t for mode, with `pause` seconds dark between runs
    static func level(_ mode: Int, _ i: Int, _ t: Double, pause: Double) -> Double {
        let n = Double(count), x = Double(i) / (n - 1), period = 2.4
        let cycle = period + pause, local = t.truncatingRemainder(dividingBy: cycle)
        if local > period { return mode == 0 ? 1 : 0 }        // Static never pauses
        let p = local / period
        func tri(_ v: Double) -> Double { v < 0.5 ? v * 2 : 2 - v * 2 }
        func near(_ pos: Double, _ w: Double) -> Double { max(0, 1 - abs(Double(i) - pos) / w) }
        let dim = 0.12
        switch Slash.modes[min(mode, Slash.modes.count - 1)] {
        case "Static": return 1
        case "Bounce": return near(tri(p) * (n - 1), 1.3)
        case "Slash": return near(p * (n + 2) - 1.5, 1.6)
        case "Loading": return Double(i) < p * (n + 1) ? 1 : dim
        case "Bit Stream":
            var h = UInt64(i * 7919 + Int(t * 6) * 104729); h ^= h >> 13; h &*= 0x5bd1e995; h ^= h >> 15
            return h % 3 == 0 ? 1 : dim
        case "Transmission": return max(near((p * n * 2).truncatingRemainder(dividingBy: n + 1) - 0.5, 0.9), dim)
        case "Flow": return 0.15 + 0.85 * (0.5 + 0.5 * sin(2 * .pi * (p * 2 - x)))
        case "Flux": return (i + Int(p * 6)) % 2 == 0 ? 1 : 0.18
        case "Phantom": return sin(.pi * p)
        case "Spectrum": return 0.15 + 0.85 * (x + p).truncatingRemainder(dividingBy: 1)
        case "Hazard": return Int(p * 6) % 2 == 0 ? 1 : 0
        case "Interfacing": return abs(x - 0.5) * 2 >= 1 - tri(p) ? 1 : dim
        case "Ramp": return x <= tri(p) ? 1 : dim
        case "Game Over": return p < 0.5 ? (Int(p * 8) % 2 == 0 ? 1 : 0) : max(0, 1 - (p - 0.5) * 2)
        case "Start": return abs(x - 0.5) * 2 <= p * 1.1 ? 1 : dim
        case "Buzzer": return Int(p * 14) % 2 == 0 ? 1 : 0.1
        default: return 1
        }
    }
}

struct LidPreview: View {
    let mode: Int, bright: Int, interval: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || bright == 0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                // the lid: dark aluminium, slightly lighter at the top, with the hinge along the bottom
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
                VStack { Spacer(); Rectangle().fill(Color(white: 0.08)).frame(height: 10).padding(.horizontal, 40) }
                strip(t)
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lid preview: Slash \(bright > 0 ? Slash.modes[min(mode, Slash.modes.count - 1)] : "off")")
    }
    func strip(_ t: Double) -> some View {
        let gain = [0, 0.45, 0.75, 1.0][min(max(bright, 0), 3)]
        return HStack(spacing: 5) {
            ForEach(0..<SlashAnim.count, id: \.self) { i in
                let v = bright == 0 ? 0 : SlashAnim.level(mode, i, reduceMotion ? 0.6 : t, pause: Double(interval) * 0.6) * gain
                Slant()
                    .fill(Color(white: 0.22 + 0.78 * v))
                    .frame(width: 36, height: 10)
                    .shadow(color: .white.opacity(0.9 * v), radius: 6 * v)
            }
        }
        .rotationEffect(.degrees(-34))
    }
}

struct SlashEditor: View {
    @ObservedObject var m: RogModel
    @State private var hovered: Int?
    var slash: Slash { m.currentSlash }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    LidPreview(mode: hovered ?? slash.mode, bright: hovered != nil ? max(slash.bright, 2) : slash.bright,
                               interval: slash.interval)
                        .frame(width: 340)
                    Text(caption).font(.system(size: 11)).foregroundStyle(T.dim)
                    Text("A drawing of the lid. The real Slash may look slightly different.").font(.system(size: 10.5)).foregroundStyle(T.faint)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Slash.modes.indices, id: \.self) { i in
                        let on = slash.bright > 0 && slash.mode == i
                        Button {
                            var s = slash; s.mode = i; if s.bright == 0 { s.bright = 2 }; m.setSlash(s)
                        } label: {
                            Text(Slash.modes[i]).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 46)
                        }
                        .buttonStyle(RogButtonStyle(selected: on, cut: 8))
                        .onHover { inside in if inside { hovered = i } else if hovered == i { hovered = nil } }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Text("Pause between runs").font(.system(size: 12)).foregroundStyle(T.text); Spacer()
                Pills(items: (0...5).map(String.init), selected: slash.interval, minWidth: 24, label: "Pause") {
                    var s = slash; s.interval = $0; m.setSlash(s)
                }
                .disabled(slash.bright == 0).opacity(slash.bright == 0 ? 0.5 : 1)
            }
            .padding(.top, 16)
            Text("Fn+F4 turns Slash on and off.").font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 10)
            ErrorLine(text: m.lightingError).padding(.top, 6)
        }
    }
    var caption: String {
        if let h = hovered { return "Preview: \(Slash.modes[h]). Click to use it." }
        return slash.bright > 0 ? "On the lid now: \(Slash.modes[min(slash.mode, Slash.modes.count - 1)])" : "Slash is off"
    }
}

struct BatteryDetails: View {
    @ObservedObject var m: RogModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                preset(60, "Desk", "Plugged in most of the day. Kindest to the battery.")
                preset(80, "Everyday", "Good balance of runtime and battery life.")
                preset(100, "Travel", "Full charge for a long day away from a socket.")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Card(pad: 14, stretch: true) {
                    Caps("Health")
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: m.st.batDesign > 5 && m.st.batFull > 0 ? String(format: "%.0f", 100.0 * Double(m.st.batFull) / Double(m.st.batDesign)) : "–")
                            .font(T.num(24)).foregroundStyle(T.text)
                        Text("%").font(T.num(12)).foregroundStyle(T.dim)
                    }
                    .padding(.top, 6)
                    Text(m.st.batFull > 0 ? "\(String(m.st.batFull)) of \(String(m.st.batDesign)) mAh design capacity" : "Not reported by the firmware")
                        .font(.system(size: 11)).foregroundStyle(T.dim)
                }
                Card(pad: 14, stretch: true) {
                    Caps("Now")
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: String(m.st.batRate)).font(T.num(24)).foregroundStyle(T.text)
                        Text("mA").font(T.num(12)).foregroundStyle(T.dim)
                    }
                    .padding(.top, 6)
                    Text(m.st.batState & 2 != 0 ? "Charging" : m.st.batState & 1 != 0 ? "Discharging" : "Not charging, held at the limit")
                        .font(.system(size: 11)).foregroundStyle(T.dim)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ErrorLine(text: m.chargeError)
        }
    }
    func preset(_ v: Int, _ name: String, _ desc: String) -> some View {
        let active = m.st.charge == v
        return Button { m.setCharge(v) } label: {
            Card(cut: 12, pad: 14, active: active, stretch: true) {
                HStack {
                    Text("\(v)%").font(T.num(20)).foregroundStyle(active ? T.red : T.text)
                    Spacer()
                    if active { Text("ACTIVE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(T.red) }
                }
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text).padding(.top, 8)
                Text(desc).font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            .contentShape(Chamfer(cut: 12))
        }
        .buttonStyle(.plain)
        .disabled(m.st.charge == nil)
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityLabel("\(name), \(v) percent").accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct SettingsEditor: View {
    @ObservedObject var m: RogModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open at login").font(.system(size: 13, weight: .medium)).foregroundStyle(T.text)
                    Text("Runs in the menu bar. Closing this window keeps hardware control active.").font(.system(size: 11)).foregroundStyle(T.dim)
                }
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) })).toggleStyle(.switch).labelsHidden().tint(T.red)
            }
            Rectangle().fill(T.line).frame(height: 1).padding(.vertical, 14)
            row("Model") { Text("ROG Zephyrus G14 · GA403WM").foregroundStyle(T.dim) }
            row("Version") { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").foregroundStyle(T.dim) }
            row("Created by") { Link("thanhnndev", destination: URL(string: "https://github.com/thanhnndev")!).foregroundStyle(T.red) }
            row("Inspired by", last: true) { Link("asusctl and asus-linux", destination: URL(string: "https://asus-linux.org")!).foregroundStyle(T.red) }
            Text("Settings are saved separately for the charger and the battery, and restored when the power source changes.")
                .font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }
    func row<C: View>(_ k: String, last: Bool = false, @ViewBuilder _ v: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack { Text(k).font(.system(size: 13)).foregroundStyle(T.text); Spacer(); v().font(.system(size: 12)) }.frame(height: 36)
            if !last { Rectangle().fill(T.line).frame(height: 1) }
        }
    }
}

// ---- Doctor: what ROG Control depends on, checked in one place ------------------------------------------------------------------
struct DoctorCheck: Identifiable {
    enum Level: Int, Comparable {
        case ok, info, warn, fail
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var color: Color { self == .ok ? .green : self == .info ? T.dim : self == .warn ? T.amber : T.red }
        var icon: String { self == .ok ? "checkmark.circle.fill" : self == .info ? "info.circle.fill" : self == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill" }
        var word: String { self == .ok ? "OK" : self == .info ? "Info" : self == .warn ? "Check" : "Problem" }
    }
    struct Fix { let label: String; let run: @MainActor () -> Void }
    // a fix the user finishes in System Settings: numbered steps, each with its own button
    struct Step { let title: String; let detail: String; let button: String; let run: @MainActor () -> String }
    let id = UUID()
    let group: String, title: String, detail: String, level: Level
    var fix: Fix? = nil
    var guide: [Step]? = nil
}

@MainActor
enum Doctor {
    static let groups = ["Driver", "Fn keys", "Audio", "Microphone and camera", "System"]
    static let rogkeydID = "com.itlmt7925.rogkeyd", rogaudiodID = "com.itlmt7925.rogaudiod"

    static func kextVersion(_ id: String) -> String? {
        guard let info = KextManagerCopyLoadedKextInfo([id] as CFArray, ["CFBundleVersion"] as CFArray)?.takeRetainedValue() as? [String: Any],
              let k = info[id] as? [String: Any] else { return nil }
        return k["CFBundleVersion"] as? String
    }
    static func espAsusWmi() -> String? {
        let url = URL(fileURLWithPath: "/Volumes/ESP/EFI/OC/Kexts/AsusWmi.kext/Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: url) else { return nil }
        return d["CFBundleVersion"] as? String
    }
    static func pref(_ pane: String) -> Fix {
        Fix(label: "Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
    }
    static func kickstart(_ label: String, _ name: String) -> Fix {
        Fix(label: "Restart \(name)") {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]; try? p.run()
        }
    }
    typealias Fix = DoctorCheck.Fix
    static let rogkeydApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RogControl/rogkeyd.app")
    @discardableResult static func shell(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
    static func restartKeyd() { shell("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(rogkeydID)"]) }
    // Input Monitoring / Accessibility for rogkeyd. A rebuilt rogkeyd keeps its name in the list but the old grant no longer
    // matches it, so the entry is reset first; rogkeyd then asks again at its restart and shows up switched off.
    static func permissionGuide(service: String, pane: String, name: String) -> [DoctorCheck.Step] {
        [DoctorCheck.Step(title: "Reset rogkeyd's old entry",
                          detail: "Takes the stale rogkeyd off the \(name) list and restarts it, so macOS asks again for this build.",
                          button: "Reset") {
            let r = shell("/usr/bin/tccutil", ["reset", service, rogkeydID])
            restartKeyd()
            return r == 0 ? "Done. macOS may now ask about rogkeyd: choose Open System Settings." : "Could not reset it: in \(name) select rogkeyd and press −."
         },
         DoctorCheck.Step(title: "Turn rogkeyd on in \(name)",
                          detail: "Switch rogkeyd on. If it is not in the list, drag rogkeyd.app from the Finder window into it (its path is on the clipboard for + and ⌘⇧G).",
                          button: "Open \(name)") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            NSWorkspace.shared.activateFileViewerSelecting([rogkeydApp])
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rogkeydApp.path, forType: .string)
            return "Settings and Finder are open; the path is on the clipboard."
         },
         DoctorCheck.Step(title: "Restart rogkeyd and check",
                          detail: "A permission counts only after rogkeyd restarts. If macOS asks to quit and reopen it, choose Later and press this.",
                          button: "Restart and check") {
            restartKeyd()
            return "Restarted. Checking in a few seconds…"
         }]
    }
    // a LaunchAgent with a PID: rogkeyd never starts NSApplication, so NSRunningApplication does not list it
    static func agentRunning(_ label: String) -> Bool {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["list", label]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let t = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return p.terminationStatus == 0 && t.contains("\"PID\" = ")
    }
    // rogkeyd's log since its last start: whether it reads the keyboard and has its event tap
    static func rogkeydLog() -> (reading: Bool?, tap: Bool?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/rogkeyd.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 65536 ? end - 65536 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        var lines = text.split(separator: "\n").map(String.init)
        if let i = lines.lastIndex(where: { $0.contains(" start: ") }) { lines = Array(lines[i...]) }
        let open = lines.last { $0.contains(": open 0x") }
        let reading = open.map { $0.contains("reading the N-KEY keyboard") }
        let tapOn = lines.lastIndex { $0.contains("event tap on") }, tapOff = lines.lastIndex { $0.contains("no Accessibility access") }
        let tap: Bool? = tapOn != nil ? (tapOff.map { $0 < tapOn! } ?? true) : tapOff != nil ? false : nil
        return (reading, tap)
    }
    // kernel panics of the last 7 days, with the first non-Apple kext in the panicked backtrace
    static func kextUUID(_ id: String) -> String? {
        guard let info = KextManagerCopyLoadedKextInfo([id] as CFArray, ["OSBundleUUID"] as CFArray)?.takeRetainedValue() as? [String: Any],
              let k = info[id] as? [String: Any], let u = k["OSBundleUUID"] else { return nil }
        if let d = u as? Data, d.count == 16 { return NSUUID(uuidBytes: [UInt8](d)).uuidString }
        return (u as? String)?.uppercased()
    }
    // the panicked kext's build (UUID in "id(version)[UUID]") still loaded? A panic of a replaced build is history.
    static func panicStillLoaded(_ p: (date: Date, kext: String?, uuid: String?, url: URL)) -> Bool {
        guard let k = p.kext, let u = p.uuid, let now = kextUUID(k) else { return true }
        return now == u
    }
    static func panics() -> [(date: Date, kext: String?, uuid: String?, url: URL)] {
        let dir = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let week = Date().addingTimeInterval(-7 * 86400)
        return files.filter { $0.pathExtension == "panic" }.compactMap { u in
            guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > week else { return nil }
            let t = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            var kext: String?, uuid: String?
            if let r = t.range(of: "Kernel Extensions in backtrace:") {
                let after = t[r.upperBound...]
                if let m = after.range(of: #"(?<![\w.])[a-z0-9-]+\.[\w.-]+\([^)]*\)\[[0-9A-Fa-f-]{36}\]"#, options: .regularExpression) {
                    let hit = String(after[m])
                    let id = String(hit[..<hit.firstIndex(of: "(")!])
                    if !id.hasPrefix("com.apple.") {
                        kext = id
                        uuid = hit.range(of: #"[0-9A-Fa-f-]{36}"#, options: .regularExpression).map { String(hit[$0]).uppercased() }
                    }
                }
            }
            return (d, kext, uuid, u)
        }.sorted { $0.date > $1.date }
    }

    static func run(_ m: RogModel) -> [DoctorCheck] {
        var c: [DoctorCheck] = []
        func add(_ g: String, _ t: String, _ d: String, _ l: DoctorCheck.Level, _ f: Fix? = nil) { c.append(DoctorCheck(group: g, title: t, detail: d, level: l, fix: f)) }
        let st = m.st, snd = m.sound

        // driver
        let loaded = kextVersion("com.itlmt7925.asuswmi")
        if !st.present {
            add("Driver", "AsusWmi", loaded == nil ? "Not loaded. It loads at boot through OpenCore (EFI/OC/Kexts)." : "Loaded (\(loaded!)) but the app cannot open it.", .fail)
        } else if st.abi < Asus.abi {
            add("Driver", "AsusWmi \(loaded ?? "")", "Older interface (ABI \(st.abi), this app speaks \(Asus.abi)): Aura needs the newer driver. Restart after installing it.", .warn)
        } else {
            add("Driver", "AsusWmi \(loaded ?? "")", "Loaded, interface ABI \(st.abi).", .ok)
        }
        if let esp = espAsusWmi() {
            if let l = loaded, l != esp { add("Driver", "Driver update waiting", "The ESP has AsusWmi \(esp), \(l) is running. Restart to load it.", .warn) }
            else { add("Driver", "ESP copy", "EFI/OC/Kexts has the running version.", .ok) }
        } else {
            add("Driver", "ESP copy", "The EFI partition is not mounted, so the installed version was not compared.", .info)
        }
        add("Driver", "N-KEY keyboard", st.hid ? "Found (USB 0b05:19b6): keyboard light, Aura and Slash work." : "Not seen yet. It is found on the first lighting command.", st.hid ? .ok : .info)

        // Fn keys
        let keyd = agentRunning(rogkeydID)
        let installed = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RogControl/rogkeyd.app").path)
        if !installed { add("Fn keys", "rogkeyd", "Not installed: the Fn keys (except mute and volume) do nothing. Install with scripts/build-rogkeys.sh --install.", .fail) }
        else if !keyd { add("Fn keys", "rogkeyd", "Installed but not running.", .fail, kickstart(rogkeydID, "rogkeyd")) }
        else {
            let log = rogkeydLog()
            switch log.reading {
            case true?: add("Fn keys", "Input Monitoring", "rogkeyd reads the N-KEY keyboard.", .ok)
            case false?: add("Fn keys", "Input Monitoring", "rogkeyd has no access, so the Fn keys do nothing. In Input Monitoring remove rogkeyd (−), add it again (+), then restart it. A new rogkeyd build always needs this.",
                             .fail, nil)
                c[c.count - 1].guide = permissionGuide(service: "ListenEvent", pane: "Privacy_ListenEvent", name: "Input Monitoring")
            case nil: add("Fn keys", "Input Monitoring", "rogkeyd has not reported yet.", .info)
            }
            switch log.tap {
            case true?: add("Fn keys", "Accessibility (Fn+F9)", "Fn+F9 opens Displays and its Cmd+P is dropped. A Cmd+P you type still prints.", .ok)
            case false?: add("Fn keys", "Accessibility (Fn+F9)", "Fn+F9 opens Displays, but its Cmd+P also reaches the app (Print dialog). Allow rogkeyd in Accessibility.", .warn)
                c[c.count - 1].guide = permissionGuide(service: "Accessibility", pane: "Privacy_Accessibility", name: "Accessibility")
            case nil: add("Fn keys", "Accessibility (Fn+F9)", "rogkeyd has not reported its event tap.", .info)
            }
        }
        if st.present, let k = Sensors.hotkey() {
            add("Fn keys", "Keys reaching AsusWmi", k.sequence == 0 ? "None since boot. Press Fn+F2 to test." : "\(k.sequence) since boot, last code \(String(format: "%02X", k.code)).", k.sequence == 0 ? .info : .ok)
        }

        // audio
        let hda = kextVersion("cn.laobamac.SimpleHDA")
        add("Audio", "SimpleHDA", hda.map { "Loaded (\($0)): the speakers and jack have a driver." } ?? "Not loaded: no built-in audio device.", hda == nil ? .fail : .ok)
        if !snd.rog { add("Audio", "ROG Speakers", "Device missing: RogAudio.driver is not installed, the sound profile is off.", .warn) }
        else if !snd.daemon { add("Audio", "rogaudiod", "Not running: ROG Speakers plays nothing.", .fail, kickstart(rogaudiodID, "rogaudiod")) }
        else { add("Audio", "rogaudiod", snd.chain ? "Running, the sound profile is on." : "Running, speakers idle (it starts when ROG Speakers plays).", .ok) }
        if let o = snd.output {
            let rogOut = snd.outputs.first(where: \.isRogSpeakers)
            add("Audio", "Output", o.isRogSpeakers ? "ROG Speakers." : "\(o.name): the sound profile only runs on ROG Speakers.", o.isRogSpeakers ? .ok : .info,
                o.isRogSpeakers || rogOut == nil ? nil : Fix(label: "Use ROG Speakers") { m.setOutput(rogOut!) })
        } else { add("Audio", "Output", "No output device.", .fail) }

        // mic and camera
        switch snd.micMuted {
        case nil: add("Microphone and camera", "Microphone", "No built-in microphone found.", .warn)
        case true?: add("Microphone and camera", "Microphone", "Muted (M3 or the switch in the window).", .info, Fix(label: "Unmute") { m.setMicMute(false) })
        case false?: add("Microphone and camera", "Microphone", snd.clearMic ? "On, Clear Mic noise reduction on." : "On, Clear Mic off.", .ok)
        }
        add("Microphone and camera", "Camera", snd.camera.map { "\($0) found." } ?? "No camera found.", snd.camera == nil ? .warn : .ok)

        // system
        let p = panics()
        if let last = p.first {
            let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
            let day = Date().timeIntervalSince(last.date) < 86400, live = panicStillLoaded(last)
            add("System", "Kernel panics", "\(p.count) in 7 days, last \(f.string(from: last.date))\(last.kext.map { ", in \($0)" } ?? "")"
                + (live ? "." : ". That build is no longer loaded."),
                day && live ? .warn : .info, Fix(label: "Show") { NSWorkspace.shared.activateFileViewerSelecting([last.url]) })
        } else { add("System", "Kernel panics", "None in 7 days.", .ok) }
        if st.batDesign > 0 && st.batFull > 0 {
            let h = Int((Double(st.batFull) / Double(st.batDesign) * 100).rounded())
            add("System", "Battery health", "\(h) % of design (\(st.batFull) of \(st.batDesign) mAh).", h < 80 ? .warn : .ok)
        }
        add("System", "Open at login", m.loginEnabled ? "On: modes and limits come back after a restart." : "Off: after a restart the firmware defaults stay until you open the app.",
            m.loginEnabled ? .ok : .warn, m.loginEnabled ? nil : Fix(label: "Turn on") { m.setLogin(true) })
        return c
    }
    static func report(_ c: [DoctorCheck]) -> String {
        var out = "ROG Control \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") Doctor, \(Date())\n"
        for g in groups {
            let rows = c.filter { $0.group == g }
            guard !rows.isEmpty else { continue }
            out += "\n\(g)\n"
            for r in rows { out += "  [\(r.level.word)] \(r.title): \(r.detail)\n" }
        }
        return out
    }
}

struct DoctorView: View {
    @ObservedObject var m: RogModel
    @State private var copied = false
    static var initialOpen: String? = nil                       // the snapshot opens a guide
    @State private var open: String? = DoctorView.initialOpen   // title of the check whose steps are shown
    @State private var notes: [String: String] = [:]          // "check/step" -> what the step's button did
    var issues: Int { m.doctor.filter { $0.level >= .warn }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: issues == 0 ? "checkmark.seal.fill" : "stethoscope").font(.system(size: 20))
                    .foregroundStyle(issues == 0 ? Color.green : (m.doctor.map(\.level).max() ?? .ok).color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issues == 0 ? "Everything checks out" : issues == 1 ? "1 thing to fix" : "\(issues) things to fix")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(T.text)
                    Text("\(m.doctor.count) checks: drivers, Fn keys, audio, microphone, camera and system").font(.system(size: 11)).foregroundStyle(T.dim)
                }
                Spacer()
                Button { m.runDoctor() } label: { Label("Run again", systemImage: "arrow.clockwise").font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28) }
                    .buttonStyle(RogButtonStyle(cut: 6))
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Doctor.report(m.doctor), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28) }
                    .buttonStyle(RogButtonStyle(cut: 6))
            }
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Doctor.groups, id: \.self) { g in
                        let rows = m.doctor.filter { $0.group == g }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Caps(g)
                                VStack(spacing: 0) {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                        row(r)
                                        if i < rows.count - 1 { Rectangle().fill(T.line).frame(height: 1) }
                                    }
                                }
                                .background(T.raised, in: Chamfer(cut: 8))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
        }
        .onAppear { if m.doctor.isEmpty { m.runDoctor() } }
    }
    func row(_ r: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.level.icon).font(.system(size: 13)).foregroundStyle(r.level.color).frame(width: 18).padding(.top, 1)
                .accessibilityLabel(r.level.word)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.text)
                Text(r.detail).font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if r.guide != nil {
                Button { open = open == r.title ? nil : r.title } label: {
                    HStack(spacing: 5) {
                        Text(open == r.title ? "Hide steps" : "Fix it").font(.system(size: 11.5, weight: .medium))
                        Image(systemName: open == r.title ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                }
                .buttonStyle(RogButtonStyle(selected: open != r.title, cut: 6))
            } else if let f = r.fix {
                Button { f.run(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.runDoctor() } } label: {
                    Text(f.label).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 10).frame(height: 26)
                        .background(r.level >= .warn ? Color.clear : T.surface, in: Chamfer(cut: 6))
                        .overlay(Chamfer(cut: 6).stroke(r.level >= .warn ? Color.clear : T.line))
                }
                .buttonStyle(RogButtonStyle(selected: r.level >= .warn, cut: 6))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .modifier(GuideBelow(r: r, shown: open == r.title, notes: $notes, recheck: recheck))
    }
    // after a step, look again (rogkeyd needs a moment to start and write its log)
    func recheck() { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { m.runDoctor() } }
}

struct GuideBelow: ViewModifier {
    let r: DoctorCheck, shown: Bool
    @Binding var notes: [String: String]
    let recheck: () -> Void
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            if shown, let steps = r.guide {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps.indices, id: \.self) { i in
                        let st = steps[i], key = "\(r.title)/\(i)"
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(T.num(11)).foregroundStyle(T.text).frame(width: 20, height: 20)
                                .background(T.surface, in: Circle()).overlay(Circle().stroke(T.line))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(T.text)
                                Text(st.detail).font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
                                if let n = notes[key] { Text(n).font(.system(size: 11)).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 8)
                            Button { notes[key] = st.run(); recheck() } label: {
                                Text(st.button).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 10).frame(height: 26)
                                    .background(T.surface, in: Chamfer(cut: 6)).overlay(Chamfer(cut: 6).stroke(T.line))
                            }
                            .buttonStyle(RogButtonStyle(cut: 6))
                        }
                    }
                }
                .padding(.leading, 40).padding(.trailing, 12).padding(.bottom, 12)
            }
        }
    }
}

// ---- status item -------------------------------------------------------------------------------------------------------------
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    var popoverHost: NSHostingController<ContentView>!
    // The popover hangs from this 1 pt window at the menu bar's bottom edge, under the icon. Anchoring to the status button
    // itself puts the popover over the bar when the menu bar auto-hides: the button's window then sits above the screen.
    let anchor: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .statusBar; w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return w
    }()
    var model: RogModel!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        model = RogModel()
        popover.behavior = .applicationDefined   // closing is ours: outside clicks, Esc, app deactivation, the icon (toggle)
        popover.animates = false
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)   // the panel uses the window's dark ROG look
        popoverHost = NSHostingController(rootView: ContentView(m: model, openWindow: { [weak self] d in self?.open(d) }))
        popoverHost.sizingOptions = .preferredContentSize   // follow SwiftUI's size, so a new line grows the panel downward
        popover.contentViewController = popoverHost
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in self?.updateIcon() }
        startHotkeys()
        updateIcon()
        setupMenus()
        if !CommandLine.arguments.contains("--background") { showWindow() }
        DistributedNotificationCenter.default().addObserver(forName: SingleInstance.showNote, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWindow() }     // a second copy was started and quit: it asked for the window
        }
    }

    // Fn keys: rogkeyd reads them and AsusWmi applies keyboard light, Slash and profile; refresh when the count moves
    private var hotkeyTimer: Timer?
    private var hotkeySeq: UInt32?
    func startHotkeys() {
        hotkeySeq = Sensors.hotkey()?.sequence
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let k = Sensors.hotkey(), k.sequence != self.hotkeySeq else { return }
                self.hotkeySeq = k.sequence
                self.model.refresh()
            }
        }
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.refresh()
        model.loadCurve()
        model.visible = true
        popover.contentSize = popoverHost.view.fittingSize   // size before showing; a later resize would grow it upward off screen
        if let bw = b.window {
            let r = bw.convertToScreen(b.convert(b.bounds, to: nil))
            let screen = NSScreen.screens.first { $0.frame.minX <= r.midX && r.midX < $0.frame.maxX } ?? NSScreen.main
            let bottom = (screen?.frame.maxY ?? r.minY + bw.frame.height) - bw.frame.height
            anchor.setFrame(NSRect(x: r.minX, y: bottom, width: r.width, height: 1), display: false)
            anchor.orderFront(nil)
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
        // Activate so the panel gets keys and the outside click. Activation raises every window of the app (later, not inside
        // this call), so a ROG window left behind other apps is taken off screen first and put back behind them when the panel
        // closes: opening the panel must not bring the window up.
        if !NSApp.isActive, let w = window, w.isVisible, !w.isMiniaturized {
            w.orderOut(nil); windowHiddenForPopover = true
        }
        openingPopover = true
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app is never active on its own, so .transient never sees the outside click
        popover.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openingPopover = false }
        watchOutsideClicks()
    }
    // Close on any click outside the panel: in other apps (global monitor), in this app's own window (local monitor), or when
    // the app stops being active. Clicks on the status button are left to toggle().
    var clickMonitors: [Any] = []
    func watchOutsideClicks() {
        stopWatchingClicks()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.popover.performClose(nil) }) {
            clickMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            guard let self, self.popover.isShown else { return e }
            let inPanel = e.window === self.popover.contentViewController?.view.window
            let onButton = e.window === self.item.button?.window
            if !inPanel && !onButton { self.popover.performClose(nil) }
            return e
        }) { clickMonitors.append(l) }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.popover.isShown, e.keyCode == 53 else { return e }   // Esc
            self.popover.performClose(nil); return nil
        }) { clickMonitors.append(k) }
    }
    func stopWatchingClicks() { clickMonitors.forEach(NSEvent.removeMonitor); clickMonitors = [] }
    func applicationDidResignActive(_ n: Notification) { if popover.isShown { popover.performClose(nil) } }
    var windowHiddenForPopover = false
    func popoverDidClose(_ n: Notification) {
        stopWatchingClicks(); anchor.orderOut(nil)
        if windowHiddenForPopover { windowHiddenForPopover = false; window?.orderBack(nil) }   // back where it was: behind the other apps
        updateVisibility()
    }
    func updateVisibility() { model.visible = popover.isShown || window?.isVisible == true || windowHiddenForPopover }
    func windowWillClose(_ n: Notification) {
        model.visible = popover.isShown
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    var openingPopover = false
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if openingPopover || popover.isShown { return false }   // activation from the status item is not a request for the window
        showWindow(); return true
    }
    func open(_ dialog: RogDialog?) {
        model.dialog = dialog
        showWindow()
    }
    @objc func showWindow() {
        windowHiddenForPopover = false
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "ROG Control"
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)   // the window is the ROG side: always dark
            w.backgroundColor = T.nsBG
            let host = NSHostingController(rootView: RogWindowView(m: model))
            host.sizingOptions = .preferredContentSize      // the window is exactly as tall as the content
            w.contentViewController = host
            w.delegate = self
            // center at the real height: the content is ~785 pt, not the 600 pt placeholder, and a saved frame from an
            // older layout put the window low on the screen
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame RogControl.MainWindow")
            let fit = host.view.fittingSize
            if fit.width > 0, fit.height > 0 { w.setContentSize(fit) }
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh(); model.loadCurve(); updateVisibility()
    }
    @objc func refreshNow() { model.refresh(); model.loadCurve() }
    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "Created by thanhnndev\ngithub.com/thanhnndev\n\nInspired by asusctl and the asus-linux community.",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.addAttribute(.link, value: URL(string: "https://github.com/thanhnndev")!, range: (credits.string as NSString).range(of: "github.com/thanhnndev"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    func setupMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About ROG Control", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ROG Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ROG Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        let open = windowMenu.addItem(withTitle: "Open ROG Control", action: #selector(showWindow), keyEquivalent: "0"); open.target = self
        let refresh = windowMenu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r"); refresh.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    // The menu bar icon is the app's ModeBadge as a template: a plate with the top-right corner cut, the mode glyph cut out of it
    static func badgeImage(_ mode: Mode) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let plate = r.insetBy(dx: 1, dy: 1), cut = plate.width * 0.25
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plate.minX, y: plate.maxY)); path.line(to: NSPoint(x: plate.maxX - cut, y: plate.maxY))
            path.line(to: NSPoint(x: plate.maxX, y: plate.maxY - cut)); path.line(to: NSPoint(x: plate.maxX, y: plate.minY))
            path.line(to: NSPoint(x: plate.minX, y: plate.minY)); path.close()
            NSColor.black.setFill(); path.fill()
            if let glyph = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9.5, weight: .bold)) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: (r.width - g.width) / 2, y: (r.height - g.height) / 2, width: g.width, height: g.height),
                           from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func updateIcon() {
        guard let b = item.button else { return }
        let mode = model.activeMode ?? .performance
        b.image = Self.badgeImage(mode)
        b.image?.accessibilityDescription = "ROG: \(mode.title)"
        var tip = "ROG: \(model.modeLabel)"
        if let t = model.tctl { tip += String(format: " · CPU %.0f°C", t) }
        if let w = model.watts { tip += String(format: " · %.0f W", w) }
        b.toolTip = tip
    }
}

// ---- command line: offscreen snapshots (layout review without hardware) -------------------------------------------------------
@MainActor
enum Snapshot {
    static func mock(manual: Bool, offline: Bool) -> RogModel {
        var st = AsusState()
        // offline = what the app really has without AsusWmi: no hardware values, no readings, no history. Only saved
        // preferences (custom limits) remain, as in the real app.
        guard !offline else { return RogModel(preview: st, tctl: nil, watts: nil, curve: nil, gpuCurve: nil) }
        st.present = true; st.ac = true; st.fanCustom = manual
        st.profile = manual ? 0 : 1; st.charge = 80; st.cpuFan = 5000; st.gpuFan = 5400; st.ppt = [45, 65, 80]
        st.gpuMux = 1; st.dgpu = 0; st.baseTgp = 55
        st.batDesign = 4580; st.batFull = 4132; st.batNow = 2440; st.batState = 0; st.batRate = 0
        st.lighting = true; st.kbd = 2; st.slash = Slash(mode: 7, bright: 2, interval: 1).packed; st.hid = true
        st.abi = Asus.abi; st.hasAura = true; st.aura = 1
        let m = RogModel(preview: st, tctl: 78, watts: 46.8,
                         curve: [43, 68, 70, 72, 74, 76, 78, 255, 1, 6, 8, 13, 18, 22, 32, 32],
                         gpuCurve: [43, 67, 68, 70, 70, 70, 70, 255, 1, 6, 8, 13, 18, 22, 32, 32])
        if manual { m.settings.mode = .manual }
        let rogOut = AudioDevice(id: 71, uid: Sound.speakersUID, name: "ROG Speakers", builtin: false)
        m.sound = SoundState(outputs: [rogOut, AudioDevice(id: 92, uid: "builtin", name: "Built-in Output", builtin: true)],
                             output: rogOut, input: AudioDevice(id: 47, uid: Sound.micUID, name: "ROG Clear Mic", builtin: false),
                             rog: true, daemon: true, chain: true, profile: "balanced", clearMic: true, micMuted: false, micInUse: true,
                             camera: "ASUS FHD webcam", cameraInUse: false)
        m.seedHistory()
        return m
    }
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let Charts and AppKit controls draw
        let fit = host.fittingSize
        if size.height == 0 { host.frame.size.height = fit.height; w.setContentSize(host.frame.size); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    // live = this machine's real readings (read only: nothing is applied), to review the layout with real values
    static func live() -> RogModel {
        let s = Sensors.read()
        let m = RogModel(preview: Asus.state(), tctl: s.tctl, watts: s.watts, curve: nil, gpuCurve: nil)
        m.sound = Sound.state()
        m.seedHistory()
        return m
    }
    static func run(dir: String, manual: Bool, offline: Bool, live: Bool = false) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: dir); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let m = live ? Self.live() : mock(manual: manual, offline: offline)
        m.runDoctor()
        let tag = live ? "-live" : offline ? "-offline" : manual ? "-manual" : ""
        render(ContentView(m: m, openWindow: { _ in }), size: NSSize(width: 320, height: 0), dark: true,
               to: out.appendingPathComponent("popover\(tag).png"))
        // the window is always dark: the main screen, then each dialog over it
        let shots: [(String, RogDialog?)] = [("1-main", nil), ("2-limits", .limits), ("3-fans", .fans), ("4-slash", .slash),
                                             ("5-battery", .battery), ("6-settings", .settings), ("7-doctor", .doctor)]
        // the guided fix, drawn whether or not this machine needs it
        var demo = DoctorCheck(group: "Fn keys", title: "Input Monitoring", detail: "rogkeyd has no access, so the Fn keys do nothing.", level: .fail)
        demo.guide = Doctor.permissionGuide(service: "ListenEvent", pane: "Privacy_ListenEvent", name: "Input Monitoring")
        let real = m.doctor
        m.doctor = real.filter { $0.group != "Driver" && !($0.group == "Fn keys" && $0.title == "Input Monitoring") }
        m.doctor.insert(demo, at: 0)
        DoctorView.initialOpen = demo.title
        m.dialog = .doctor
        render(RogWindowView(m: m), size: NSSize(width: 1120, height: 0), dark: true, to: out.appendingPathComponent("window-7b-doctor-guide\(tag).png"))
        DoctorView.initialOpen = nil; m.doctor = real
        for (name, d) in shots {
            m.dialog = d
            render(RogWindowView(m: m), size: NSSize(width: 1120, height: 0), dark: true,
                   to: out.appendingPathComponent("window-\(name)\(tag).png"))
        }
        for mode in Mode.allCases {         // menu bar icons, drawn at 4x for review
            let img = AppDelegate.badgeImage(mode)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 18, height: 18)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 18, height: 18).fill()
            img.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("menubar-\(mode.rawValue).png"))
        }
        print("snapshots in \(out.path)")
    }
}

// ---- command line: profile bench -------------------------------------------------------------------------------------------------
final class Load {
    private var running = true
    private let lock = NSLock()
    func start(_ n: Int) {
        for _ in 0..<n {
            Thread.detachNewThread { [self] in
                var x: UInt64 = 88172645463325252
                while lock.withLock({ running }) {
                    for _ in 0..<200_000 { x ^= x << 13; x ^= x >> 7; x ^= x << 17 }
                }
                if x == 42 { print("") }
            }
        }
    }
    func stop() { lock.withLock { running = false } }
}

func bench(seconds: Int) -> Int32 {
    let st0 = Asus.state()
    guard st0.present else { print("AsusWmi is not loaded"); return 1 }
    let ncpu = ProcessInfo.processInfo.activeProcessorCount
    print("RogControl bench: \(ncpu) busy threads, \(seconds) s per mode, \(st0.ac ? "on AC" : "on battery"); previous profile \(st0.profile.map(String.init) ?? "?")")
    print("mode         avg W   max W   Tctl max   CPU fan   GPU fan   Zen5 MHz   Zen5c MHz")
    var modes: [Mode] = [.silent, .performance]
    if st0.ac { modes.append(.turbo) }
    for mode in modes {
        guard Asus.set(.profile, mode.firmwareProfile) == KERN_SUCCESS else { print("\(mode.title): profile refused"); continue }
        Thread.sleep(forTimeInterval: 3)                       // let the firmware settle, fans spin down/up a little
        let load = Load(); load.start(ncpu)
        _ = Sensors.read()
        var ws: [Double] = [], tmax = 0.0, cf = 0, gf = 0
        for i in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            let s = Sensors.read()
            if i >= 2, let w = s.watts { ws.append(w) }       // skip the first seconds of the fast boost
            tmax = max(tmax, s.tctl ?? 0)
            let st = Asus.state(); cf = max(cf, st.cpuFan); gf = max(gf, st.gpuFan)
        }
        let clk = Sensors.clocks()
        load.stop()
        let avg = ws.isEmpty ? 0 : ws.reduce(0, +) / Double(ws.count)
        print(String(format: "%-11@ %6.1f  %6.1f   %6.1f°C   %7d   %7d   %8d   %9d", mode.title as NSString, avg, ws.max() ?? 0, tmax, cf, gf,
                     clk?.big ?? 0, clk?.little ?? 0))
        Thread.sleep(forTimeInterval: 5)                       // cool down between modes
    }
    if let p = st0.profile { Asus.set(.profile, p) }
    print("previous profile restored (custom fan curves and power limits, if any, are reset; RogControl re-applies its mode at the next power change or start)")
    return 0
}

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--snapshot" {
    MainActor.assumeIsolated { Snapshot.run(dir: args[2], manual: args.contains("--manual"), offline: args.contains("--offline"), live: args.contains("--live")) }
    exit(0)
}
if args.count >= 2 && args[1] == "--doctor" {             // the Doctor report on stdout (read only)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let s = Sensors.read()
        let m = RogModel(preview: Asus.state(), tctl: s.tctl, watts: s.watts, curve: nil, gpuCurve: nil)
        m.sound = Sound.state(); m.loginEnabled = LoginItem.enabled
        print(Doctor.report(Doctor.run(m)), terminator: "")
    }
    exit(0)
}
if args.count >= 2 && args[1] == "--bench" {
    exit(bench(seconds: args.count >= 3 ? max(5, Int(args[2]) ?? 20) : 20))
}

// One ROG Control per user. Two paths start it: the LaunchAgent at login (--background) and LaunchServices (Finder, Spotlight,
// M4, or macOS reopening it at login). launchd runs the binary without asking whether one is already there, so the first copy
// holds an flock for its lifetime; a later copy asks it to show the window (unless it is the background start) and quits.
enum SingleInstance {
    static let showNote = Notification.Name("com.itlmt7925.RogControl.show")
    nonisolated(unsafe) static var fd: Int32 = -1
    static func claim() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RogControl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(dir.appendingPathComponent("RogControl.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }              // no lock file: better two copies than none
        return flock(fd, LOCK_EX | LOCK_NB) == 0         // released by the kernel when this process exits
    }
}
if !SingleInstance.claim() {
    if !CommandLine.arguments.contains("--background") {
        DistributedNotificationCenter.default().postNotificationName(SingleInstance.showNote, object: nil, userInfo: nil, deliverImmediately: true)
    }
    print("RogControl is already running: \(CommandLine.arguments.contains("--background") ? "nothing to do" : "asked it to show its window")")
    exit(0)
}

MainActor.assumeIsolated {                     // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

# rog-control-macos

<p align="center"><img src="docs/images/app-icon.png" alt="ROG Control app icon" width="128"></p>

ROG Control Center for macOS on the **ASUS ROG Zephyrus G14 (GA403WM)**: performance profiles, CPU power limits, fan
curves and speeds, battery charge limit, keyboard light and Slash lighting from a menu bar app, backed by two kexts.

macOS has no driver for ASUS's ACPI WMI device, so the embedded controller keeps the profile and power limits it booted
with and nothing on macOS can change them. This repo is the macOS counterpart of Linux `asus-wmi` / `asus-armoury`
(the kext) and of `asusd` / `rog-control-center` from [asusctl](https://github.com/opengamingcollective/asusctl) (the app).
No asusctl code is included; see [NOTICE.md](NOTICE.md).

> Part of the [GA403WM Hackintosh](https://github.com/thanhnndev/ga403wm-hackintosh) project (OpenCore EFI and index of the
> parts). Sibling repo for the radio chip: [mt7925-macos](https://github.com/thanhnndev/mt7925-macos) (Wi-Fi and Bluetooth).

**Vibe-coded, kernel code.** The kexts run in the kernel. Read the source before you install anything, and keep a way to
boot without them (OpenCore picker, remove the kext from `config.plist`).

## What is in it

| Part | Where | What it does |
|---|---|---|
| `AsusWmi.kext` | `kexts/AsusWmi` | Matches the ACPI `ATKD` device (`PNP0C14`, `_UID "ATK"`) and calls its WMI methods like `asus-wmi`: platform profile, PPT limits (range-checked for AC or battery), fan curves, fan speeds, charge limit, keyboard light and Aura (N-KEY HID reports), Slash lighting, the Fn keys rogkeyd passes on (`kAsusUcKey`, ABI 5) |
| `AmdCppc.kext` | `kexts/AmdCppc` | Ryzen AI 9 HX 370: Tctl and package power (`debug.amdcppc.sensors`), per-CPU clocks (`debug.amdcppc.freq`), CPPC boost and EPP controls |
| `RogControl.app` | `macos/RogControl` | SwiftUI menu bar app plus a window: mode, live readings, battery, Custom limits, lighting, sound, microphone and camera, and a Doctor that checks the whole setup. Talks to AsusWmi through its user client, no sudo. One copy per user |
| `rogkeyd.app` | `macos/RogKeys` | LaunchAgent that reads the N-KEY Fn keys (vendor report 0x5A), which macOS drops, and hands them to AsusWmi; does mic mute, airplane mode, Fn+F9 and M4 itself. Needs Input Monitoring (and Accessibility for Fn+F9) |
| `AmdCppcPolicy` | `macos/AmdCppcPolicy` | Root LaunchDaemon that applies the CPPC policy after boot and wake |

## Status

Reference unit: GA403WM, Ryzen AI 9 HX 370. Owner-confirmed on 2026-10-12, when the machine ran macOS 15 (24H32): profiles
(Silent / Balanced / Turbo), Manual power limits, fan curves, fan speeds, charge limit (60 / 80 / 100 %), per-power-source
settings, keyboard light, Slash lighting, the RogControl app. macOS 26 (Tahoe) has **not** been checked. Other ASUS models
are untested; the power-limit ranges are the GA403WM's. Per-feature detail and the open items are in
[docs/ASUSCTL-MACOS.md](docs/ASUSCTL-MACOS.md).

## Screenshots

<p align="center"><img src="docs/images/rogcontrol-window.png" alt="RogControl window: live readings, mode, battery, custom limits and lighting on one screen" width="860"></p>
<p align="center"><em>One screen: live readings and mode on top, battery, Custom limits and lighting below. Setup opens as a dialog.</em></p>

<p align="center"><img src="docs/images/rogcontrol-popover.png" alt="RogControl menu bar panel" width="320"></p>
<p align="center"><em>Menu bar panel</em></p>

<p align="center"><img src="docs/images/rogcontrol-doctor.png" alt="Doctor dialog: drivers, Fn keys, audio, microphone, camera and system checks" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-doctor-fix.png" alt="Doctor guided fix for rogkeyd's Input Monitoring permission" width="430"></p>
<p align="center"><em>Doctor: every dependency in one list, and the guided fix for a missing permission</em></p>

<p align="center"><img src="docs/images/rogcontrol-limits.png" alt="Custom limits dialog" width="430">&nbsp;&nbsp;<img src="docs/images/fan-curves.png" alt="Fan curves dialog" width="430"></p>
<p align="center"><em>Custom limits dialog (burst, short boost, sustained in plain words) and the firmware fan curves</em></p>

<p align="center"><img src="docs/images/rogcontrol-battery.png" alt="Battery dialog" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-lighting.png" alt="Slash animations dialog" width="430"></p>
<p align="center"><em>Battery dialog (charge limit presets, health) and Slash animations with a G14 lid preview</em></p>

<p align="center"><img src="docs/images/rogcontrol-general.png" alt="Settings dialog" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-offline.png" alt="RogControl window without AsusWmi loaded" width="430"></p>
<p align="center"><em>Settings, and the window when AsusWmi is not loaded</em></p>

<p align="center"><img src="docs/images/rogcontrol-popover-offline.png" alt="RogControl menu bar panel without AsusWmi loaded" width="320"></p>
<p align="center"><em>Panel when AsusWmi is not loaded: controls are off, nothing is guessed</em></p>

<p align="center"><img src="docs/images/logo-concepts.png" alt="App icon concepts" width="720"></p>
<p align="center"><em>App icon concepts; C (Slash shard) was chosen. Screenshots are offscreen renders with sample data.</em></p>

## Releases

| Release | Contents |
|---|---|
| [rogcontrol-v0.5.2](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.5.2) | `RogControl-0.5.2.dmg`: Doctor (checks and guided fixes), Aura control, sound row on the grid, one copy per user. `AsusWmi-0.2.2.kext.zip` (Fn keys, Aura, the Fn+F7/F8 panic fix; ABI 5) and `rogkeyd-1.2.app.zip` (Fn keys reader); see [docs/FN-HOTKEYS.md](docs/FN-HOTKEYS.md) |
| [rogcontrol-v0.4.0](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.4.0) | `RogControl-0.4.0.dmg`: sound output, sound profile, microphone, Clear Mic and camera |
| [rogcontrol-v0.3.3](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.3.3) | `RogControl-0.3.3.dmg`: one-screen window with dialogs, no spare space, menu bar icon in the app badge style, steadier temperature and power readings; open it and drag the app into Applications. Kexts unchanged, still in `rog-v1.0` |
| [rog-v1.0](https://github.com/thanhnndev/rog-control-macos/releases/tag/rog-v1.0) | `AsusWmi.kext`, `AmdCppc.kext`, `AmdCppcPolicy`, `RogControl.app`, `SHA256SUMS.txt`. Binaries copied unchanged from `kext-v1.1` of the EFI repo; same checksums |

## Build

On macOS with the Xcode command line tools (the kexts cannot be built on Linux):

```bash
bash scripts/build.sh                      # build/AsusWmi.kext, build/AmdCppc.kext
bash scripts/build-amdcppc-policy.sh       # build/AmdCppcPolicy
bash scripts/test-rogcontrol.sh            # fan-curve decoding, never writes hardware
bash scripts/build-rogcontrol.sh           # build/RogControl.app
bash scripts/build-rogcontrol.sh --install # copy to /Applications, start at login
bash scripts/build-rogkeys.sh --install    # rogkeyd LaunchAgent (Fn keys); then grant Input Monitoring
bash scripts/build-dmg.sh                  # build/RogControl-<version>.dmg, drag-to-Applications installer
```

CI builds the same on `macos-15` and uploads the zips (ad-hoc signed; nothing is notarized).

## Install the kexts

OpenCore loads what `config.plist` lists, by path. Copy the kext into `EFI/OC/Kexts`, add it under `Kernel > Add`, reboot.
`scripts/macos-install-kext.sh AsusWmi` does the copy and keeps the old kext in `EFI/OC/Kexts-backup`; `--undo` puts it
back. It does not edit `config.plist`. AmdCppc and its policy daemon: [docs/CPU-POWER.md](docs/CPU-POWER.md).

## Docs

* [docs/ASUSCTL-MACOS.md](docs/ASUSCTL-MACOS.md): feature map, WMI device ids, ABI, measurements.
* [docs/rog-control-design.md](docs/rog-control-design.md): menu bar and window design decisions, fan-curve drawing rules.
* [docs/CPU-POWER.md](docs/CPU-POWER.md): AmdCppc audit and the CPPC policy.
* [docs/FN-HOTKEYS.md](docs/FN-HOTKEYS.md): the Fn key map, rogkeyd, and why the keyboard driver is not replaced.
* [docs/AUDIO-ROG.md](docs/AUDIO-ROG.md) (branch `dev/audio`).

## Branches

* `main`: the shipped menu bar app, rogkeyd and the two kexts.
* `dev/fn-hotkeys`: an earlier Fn key attempt through ATKD WMI, which never fires on this machine. Superseded by rogkeyd; not merged.
* `dev/audio`: a from-scratch rewrite of the app with an audio page, the RogAudio HAL plug-in and mic chain. Speakers were
  still silent in audible tests when the branch was last touched. Not merged.

The history of these files was split out of `thanhnndev/ga403wm-hackintosh` with `git filter-repo`; commits keep their
original dates and authors.

## License

[Clear BSD](LICENSE). Credits and third-party notes: [NOTICE.md](NOTICE.md).

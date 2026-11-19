// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
//
// StrixDgpuGate 0.2.1: "Eco" for the RTX 5060 on the GA403WM under macOS Tahoe 26 (Darwin 25.x).
//
// The NullMoth NVIDIA stack (NVRM and the kexts that sit on it) binds the RTX at boot and has no runtime power management,
// so the card can only be powered off when NVRM never attached to it. StrixDgpuClaim matches the RTX with a higher probe
// score than NVRM (2000 vs 1000). Its probe() says yes only when the stored GPU mode asks for Eco; then NVRM, NVRMFB,
// NVAccel and NVRMAGDC never start, and this driver moves the card to D3hot and runs \_SB.PCI0.GPP9.PG00._OFF.
// 0.2.0: once the card is off, its display and audio nubs are terminated (off the bus). A display-class nub that nothing
// publishes made WindowServer's GPUWranglerWaitForPublish wait its full 60 s on every Eco boot (see takeOffBus).
// 0.2.1: off-bus is no longer one-shot. Every power-off pass (3 s after the claim, 3 s after each wake, after a second claim
// in the same boot, and when the 90 s / 5 min re-check finds GPP9.GSTA back at 1 or RTX nubs back on the bus) walks the
// RTX root port's PCI children, so functions that a hot-plug scan re-created are powered off and terminated again.
// In every other case probe() returns null and NVRM binds as if this kext did not exist.
//
// AsusWmi: with the nubs gone, its rtxForeignDriver() finds no RTX, so ASUS_GPF_LIVE_OK stays clear and ASUS_GPU_SET_DGPU
// (live WMI eject) answers NotPermitted. Nothing calls it; the GPU-mode page reads gate-held / gate-powered-off /
// gate-effective and stores the next-boot mode with ASUS_GPU_SET_MODE, which needs neither.
//
//   NVRAM  strix-gpu-mode = standard | eco | optimized   written by AsusWmi (ABI 6); optimized = Eco only when the boot
//                                                        starts on battery (ACPI0003._PSR == 0), decided once, here
//   NVRAM  strix-gpu-eco-try = 1                          set when Eco is claimed, cleared after 90 s of uptime. Still 1 at
//                                                        the next probe = the last Eco boot did not finish: stand down once
//   NVRAM  strix-gpu-eco-boots / strix-gpu-eco-cleared    evidence: Eco boot counter; "<counter>:<awake s>" written before try is cleared.
//                                                        try=1 with cleared == boots is a lost write (stale), not a failed boot.
//                                                        try is cleared at 90 s, again at 5 min, and on WillRestart / WillPowerOff.
//                                                        0.2.1: cleared = "<counter>:<awake s>:ws<0|1>", ws1 = a WindowServer
//                                                        user client existed at the last clear (the desktop came up)
//   NVRAM  strix-gpu-keepbus = 1                          same as strixgate_keepbus=1 (sudo nvram strix-gpu-keepbus=1; -d to undo)
//   boot-args  -strixgate_off      never claim (recovery)
//              strixgate_keepbus=1 power the card off but leave its nubs registered (0.1.x behaviour; costs 60 s at login)
//              strixgate_dry=1     claim the card (NVRM stays off) but do not power it off: first-install test
//
// Properties of the IOResources service StrixDgpuGate (read by AsusWmi): gate-effective (0 standard, 1 eco),
// gate-held, gate-powered-off, gate-tripped, pg00-sta, gate-state (text). Off-bus status: gate-off-bus (no RTX nub left after
// the last pass), gate-offbus-terminations (nubs terminated this boot), gate-offbus-passes, gsta-recheck, gate-keepbus, gate-ws-seen.
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOLib.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/pci/IOPCIBridge.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <kern/thread_call.h>
#include <libkern/version.h>
#include <kern/clock.h>
#include <libkern/OSAtomic.h>
#include <string.h>

#define VAR_MODE "strix-gpu-mode"
#define VAR_TRY  "strix-gpu-eco-try"
#define VAR_BOOTS   "strix-gpu-eco-boots"      // counts Eco claims (one per boot); written in start()
#define VAR_CLEARED "strix-gpu-eco-cleared"    // "<boot counter>:<awake uptime s>" written just before try is cleared

static void cp(char *d, const char *s, size_t n) { size_t i = 0; for (; i + 1 < n && s[i]; i++) d[i] = s[i]; d[i] = 0; }
static bool gHeld, gOff, gTripped, gDry, gOffBus;
static int gEffective = 0;
static uint32_t gSta = ~0u, gGstaBefore = ~0u, gGstaAfter = ~0u, gPsc = ~0u, gVendorAfter = ~0u;
static char gState[96] = "not probed";
// loop-guard evidence (published as gate-* properties, see publish())
static uint32_t gBootN, gClaimStarts, gClearStage, gClearUp;
static bool gCleared, gStaleTry;
static char gTryAtProbe[8], gPrevBoots[16], gPrevCleared[32], gClearedStr[32], gTryReadback[8];
static uint32_t gOffBusTerms, gOffBusPasses, gGstaRecheck = ~0u;
static int gWsSeen = -1;            // -1 not checked yet, 0 no WindowServer user client, 1 seen
static bool gKeepBus;
static volatile bool gStopping;
// power-source heartbeat (see hbTick): last 32 samples, event counters
#define HB_RING 32
#define HB_TICKS 80                 // 80 x 250 ms = 20 s
static char gRing[HB_RING][44];
static uint32_t gRingN, gHbEvents, gHbFlips, gHbFirstFlipMs = ~0u, gHbMaxGapMs, gHbLastN;
static char gHbSrc[16] = "none";
static int gHbAc = -1;
static volatile SInt32 gHbRunning;
class StrixDgpuGate;
static StrixDgpuGate *gInfo;

static IORegistryEntry *opts() { return IORegistryEntry::fromPath("/options", gIODTPlane); }

static bool readVar(const char *k, char *out, size_t n)
{
    out[0] = 0;
    IORegistryEntry *o = opts();
    if (!o) return false;
    OSObject *v = o->getProperty(k);
    if (OSString *s = OSDynamicCast(OSString, v)) cp(out, s->getCStringNoCopy(), n);
    else if (OSData *d = OSDynamicCast(OSData, v)) {
        size_t l = d->getLength() < n - 1 ? d->getLength() : n - 1;
        memcpy(out, d->getBytesNoCopy(), l);
        out[l] = 0;
    }
    o->release();
    return out[0] != 0;
}

static void writeVar(const char *k, const char *val, bool sync = true)   // from a kernel thread only
{
    IORegistryEntry *o = opts();
    if (!o) return;
    if (OSString *s = OSString::withCString(val)) { o->setProperty(k, s); s->release(); }
    if (sync) if (OSString *key = OSString::withCString(k)) { o->setProperty("IONVRAM-FORCESYNCNOW-PROPERTY", key); key->release(); }
    o->release();
}

static uint32_t parseU(const char *s) { uint32_t x = 0; for (; *s >= '0' && *s <= '9'; s++) x = x * 10 + (*s - '0'); return x; }
static uint32_t uptimeS() { uint64_t ns; absolutetime_to_nanoseconds(mach_absolute_time(), &ns); return (uint32_t)(ns / 1000000000ULL); }

// every write of the loop-guard flag goes through here, so the log shows who wrote what and when
static void setTry(const char *v, const char *why)
{
    IOLog("StrixDgpuGate: %s=%s (%s) at awake uptime %u s, boot counter %u\n", VAR_TRY, v, why, (unsigned)uptimeS(), (unsigned)gBootN);
    writeVar(VAR_TRY, v);
}

static bool onBattery(bool *known)
{
    *known = false;
    bool bat = false;
    if (OSDictionary *m = IOService::nameMatching("ACPI0003")) {
        IOService *s = IOService::copyMatchingService(m);
        m->release();
        if (IOACPIPlatformDevice *ac = s ? OSDynamicCast(IOACPIPlatformDevice, s) : nullptr) {
            UInt32 r = 0;
            if (ac->evaluateInteger("_PSR", &r) == kIOReturnSuccess) { *known = true; bat = r == 0; }
        }
        if (s) s->release();
    }
    return bat;
}

// ---- status service ------------------------------------------------------------------------------------------------------
class StrixDgpuGate : public IOService {
    OSDeclareDefaultStructors(StrixDgpuGate)
public:
    bool start(IOService *provider) override { if (!IOService::start(provider)) return false; gInfo = this; publish(); registerService(); return true; }
    void stop(IOService *provider) override;
    void publish()
    {
        setProperty("gate-effective", (unsigned long long)gEffective, 32);
        setProperty("gate-held", gHeld);
        setProperty("gate-powered-off", gOff);
        setProperty("gate-off-bus", gOffBus);
        setProperty("gate-offbus-terminations", (unsigned long long)gOffBusTerms, 32);
        setProperty("gate-offbus-passes", (unsigned long long)gOffBusPasses, 32);
        setProperty("gate-keepbus", gKeepBus);
        if (gGstaRecheck != ~0u) setProperty("gsta-recheck", (unsigned long long)gGstaRecheck, 32);
        if (gWsSeen >= 0) setProperty("gate-ws-seen", gWsSeen == 1);
        setProperty("gate-tripped", gTripped);
        if (gSta != ~0u) setProperty("pg00-sta", (unsigned long long)gSta, 32);
        if (gGstaBefore != ~0u) setProperty("gsta-before", (unsigned long long)gGstaBefore, 32);
        if (gGstaAfter != ~0u) setProperty("gsta-after", (unsigned long long)gGstaAfter, 32);
        if (gPsc != ~0u) setProperty("psc", (unsigned long long)gPsc, 32);
        if (gVendorAfter != ~0u) setProperty("vendor-after", (unsigned long long)gVendorAfter, 32);
        setProperty("gate-state", gState);
        setProperty("gate-eco-boots", (unsigned long long)gBootN, 32);
        setProperty("gate-claim-starts", (unsigned long long)gClaimStarts, 32);
        setProperty("gate-try-stale", gStaleTry);
        if (gTryAtProbe[0]) setProperty("gate-try-at-probe", gTryAtProbe);
        if (gPrevBoots[0]) setProperty("gate-prev-boots", gPrevBoots);
        if (gPrevCleared[0]) setProperty("gate-prev-cleared", gPrevCleared);
        if (gClearedStr[0]) setProperty("gate-eco-cleared", gClearedStr);
        if (gTryReadback[0]) setProperty("gate-try-readback", gTryReadback);
        setProperty("gate-clear-stage", (unsigned long long)gClearStage, 32);
        setProperty("hb-events", (unsigned long long)gHbEvents, 32);
        setProperty("hb-src", gHbSrc);
        setProperty("hb-ac", (unsigned long long)(gHbAc < 0 ? 0xff : gHbAc), 32);
        setProperty("hb-ticks", (unsigned long long)gHbLastN, 32);
        setProperty("hb-gsta-flips", (unsigned long long)gHbFlips, 32);
        if (gHbFirstFlipMs != ~0u) setProperty("hb-first-flip-ms", (unsigned long long)gHbFirstFlipMs, 32);
        setProperty("hb-max-gap-ms", (unsigned long long)gHbMaxGapMs, 32);
    }
    void publishRing()
    {
        if (OSArray *a = OSArray::withCapacity(HB_RING)) {
            uint32_t n = gRingN < HB_RING ? gRingN : HB_RING;
            for (uint32_t i = 0; i < n; i++) {
                uint32_t idx = (gRingN - n + i) % HB_RING;
                if (OSString *e = OSString::withCString(gRing[idx])) { a->setObject(e); e->release(); }
            }
            setProperty("hb-ring", a);
            a->release();
        }
    }
};
OSDefineMetaClassAndStructors(StrixDgpuGate, IOService)

// ---- Eco state that outlives the claim ----------------------------------------------------------------------------------
// After the card is off, the RTX display and audio nubs are terminated ("off the bus", see powerOff). That stops
// StrixDgpuClaim, so everything that must keep running for the rest of the boot (loop-guard clears, re-off after resume,
// power-source heartbeat) lives here, not in the claim object. Thread calls take no parameter. Config space is reached through
// the parent bridge with the nub's saved address, which stays valid after the nub is gone.
static IOPCIBridge *gBridge;                       // retained; parent of the RTX display function (GPP9)
static IOPCIAddressSpace gGpuSpace, gAudSpace;
static bool gHaveAud;
static uint8_t gGpuPm, gAudPm;                     // PCI power-management capability offsets, found while the card was powered
static IOLock *gOffLock;                           // one power-off pass at a time (wake, re-check and a second claim can overlap)
static thread_call_t gOffCall, gTryCall, gHbCall, gPollCall;
static IONotifier *gWake, *gAcadNote;
static IOACPIPlatformDevice *gHbGpp, *gHbPegp;
static IOService *gBatt;
static int gBattLast = -1;
static uint64_t gHbT0, gHbPrev;
static uint32_t gHbN, gHbSync = 8, gHbLastG = ~0u, gHbVendor = ~0u, gHbPmcsr = ~0u, gHbPsc = ~0u;

// Unload only (the claim keeps the kext loaded while it holds the RTX). Notifiers first, so nothing new is scheduled; the
// self-rescheduling calls (heartbeat, battery poll, clear) check gStopping before re-entering.
void StrixDgpuGate::stop(IOService *provider)
{
    gStopping = true;
    if (gWake) { gWake->remove(); gWake = nullptr; }
    if (gAcadNote) { gAcadNote->remove(); gAcadNote = nullptr; }
    thread_call_t *calls[4] = { &gOffCall, &gTryCall, &gHbCall, &gPollCall };
    for (thread_call_t *c : calls) {
        if (!*c) continue;
        thread_call_cancel_wait(*c);
        thread_call_cancel(*c);            // an invocation that re-entered itself before it saw gStopping
        thread_call_free(*c);
        *c = nullptr;
    }
    if (gBatt) { gBatt->release(); gBatt = nullptr; }
    if (gHbGpp) { gHbGpp->release(); gHbGpp = nullptr; }
    if (gHbPegp) { gHbPegp->release(); gHbPegp = nullptr; }
    if (gBridge) { gBridge->release(); gBridge = nullptr; }
    if (gOffLock) { IOLockFree(gOffLock); gOffLock = nullptr; }
    gInfo = nullptr;
    IOService::stop(provider);
}

static uint16_t cfg16(const IOPCIAddressSpace &sp, uint8_t off) { return gBridge ? gBridge->configRead16(sp, off) : 0xffff; }
static void cfgW16(const IOPCIAddressSpace &sp, uint8_t off, uint16_t v) { if (gBridge) gBridge->configWrite16(sp, off, v); }

static void offThread(thread_call_param_t, thread_call_param_t);
static void clearTry(thread_call_param_t, thread_call_param_t);
static void hbThread(thread_call_param_t, thread_call_param_t);
static void pollThread(thread_call_param_t, thread_call_param_t);
static IOReturn pmMsg(void *, void *, UInt32 type, IOService *, void *, vm_size_t);
static IOReturn acadMsg(void *, void *, UInt32 type, IOService *, void *, vm_size_t);

// ---- the claim -----------------------------------------------------------------------------------------------------------
class StrixDgpuClaim : public IOService {
    OSDeclareDefaultStructors(StrixDgpuClaim)
public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
};
OSDefineMetaClassAndStructors(StrixDgpuClaim, IOService)


static void note(const char *s)
{
    cp(gState, s, sizeof gState);
    IOLog("StrixDgpuGate: %s\n", s);
    if (gInfo) gInfo->publish();
}

// One decision per boot, on the first probe of any personality; every later probe (other personality, re-match) reads it.
static bool gDecided, gEco;

static bool decide()
{
    if (gDecided) return gEco;
    gDecided = true;
    gEco = false;
    gEffective = 0;
    if (version_major != 25) { note("standard: not Darwin 25.x"); return false; }
    if (PE_parse_boot_argn("-strixgate_off", nullptr, 0)) { note("standard: -strixgate_off"); return false; }
    char mode[16], tr[8];
    readVar(VAR_MODE, mode, sizeof mode);
    bool eco = strncmp(mode, "eco", 3) == 0;
    if (strncmp(mode, "optimized", 9) == 0) {
        bool known = false, bat = onBattery(&known);
        if (!known) { note("standard: optimized, power source unknown"); return false; }
        eco = bat;
    }
    if (!eco) { note("standard: NVRM drives the RTX"); return false; }
    readVar(VAR_TRY, tr, sizeof tr);
    cp(gTryAtProbe, tr, sizeof gTryAtProbe);
    readVar(VAR_BOOTS, gPrevBoots, sizeof gPrevBoots);
    readVar(VAR_CLEARED, gPrevCleared, sizeof gPrevCleared);
    IOLog("StrixDgpuGate: probe sees %s=%s %s=%s %s=%s\n", VAR_TRY, tr[0] ? tr : "(none)", VAR_BOOTS, gPrevBoots[0] ? gPrevBoots : "(none)", VAR_CLEARED, gPrevCleared[0] ? gPrevCleared : "(none)");
    if (tr[0] == '1') {
        // try=1 means the last Eco boot did not reach its clear. But if the cleared record names that same boot, the boot did
        // finish and only the try=0 write was lost: that is a stale flag, not a failed boot.
        uint32_t prev = parseU(gPrevBoots), done = parseU(gPrevCleared);
        if (prev && done == prev) {
            gStaleTry = true;
            setTry("0", "stale: previous Eco boot recorded as cleared");
        } else {
            gTripped = true;
            setTry("0", "loop guard tripped");
            note("standard: loop guard (previous Eco boot did not finish)");
            return false;
        }
    }
    gEco = true;
    return true;
}

IOService *StrixDgpuClaim::probe(IOService *provider, SInt32 *score)
{
    return decide() ? IOService::probe(provider, score) : nullptr;
}

// NVAccel matches the RTX in IOMatchCategory IOAccelerator and its start() polls for NVRM for up to 30 s. In Eco this
// personality takes that category: it starts, never registers, so NVAccel is never probed.
class StrixDgpuAccelHold : public IOService {
    OSDeclareDefaultStructors(StrixDgpuAccelHold)
public:
    IOService *probe(IOService *provider, SInt32 *score) override { return decide() ? IOService::probe(provider, score) : nullptr; }
    bool start(IOService *provider) override { return IOService::start(provider); }   // no registerService()
};
OSDefineMetaClassAndStructors(StrixDgpuAccelHold, IOService)

static void scheduleOff(uint32_t ms, const char *why)
{
    if (gStopping || !gHeld || gDry || !gOffCall) return;
    IOLog("StrixDgpuGate: power-off pass in %u ms (%s)\n", (unsigned)ms, why);
    uint64_t dl;
    clock_interval_to_deadline(ms, kMillisecondScale, &dl);
    thread_call_enter_delayed(gOffCall, dl);
}

bool StrixDgpuClaim::start(IOService *provider)
{
    if (!IOService::start(provider)) return false;
    IOPCIDevice *gpu = OSDynamicCast(IOPCIDevice, provider);
    if (!gpu) return false;
    if (gClaimStarts++ != 0) {
        // Once per boot for everything that arms state. A second claim means the RTX display function was enumerated again
        // (a hot-plug scan after GPP9 came back to D0 can re-create the nubs): run a power-off pass, which walks GPP9's children.
        IOLog("StrixDgpuGate: second Claim start() in this boot (#%u)\n", (unsigned)gClaimStarts);
        if (gInfo) gInfo->publish();
        if (OSDynamicCast(IOPCIBridge, gpu->getProvider()) == gBridge) scheduleOff(3000, "RTX nub re-created");
        else IOLog("StrixDgpuGate: second claim is not under the saved bridge, left alone\n");
        return true;
    }
    IOPCIBridge *br = OSDynamicCast(IOPCIBridge, gpu->getProvider());
    if (!br) { note("eco: RTX has no PCI bridge parent, not held"); return false; }
    if (!(gOffLock = IOLockAlloc())) { note("eco: no memory for the power-off lock, not held"); return false; }
    br->retain(); gBridge = br;
    gGpuSpace = gpu->space;            // the PM capability offsets are found in the first power-off pass (powerOff)
    gHeld = true; gEffective = 1;
    uint32_t v = 0;
    gDry = PE_parse_boot_argn("strixgate_dry", &v, sizeof v) && v == 1;
    v = 0;
    char kb[4];
    gKeepBus = (PE_parse_boot_argn("strixgate_keepbus", &v, sizeof v) && v == 1) || (readVar("strix-gpu-keepbus", kb, sizeof kb) && kb[0] == '1');
    gOffCall = thread_call_allocate(&offThread, nullptr);
    gTryCall = thread_call_allocate(&clearTry, nullptr);
    gHbCall = thread_call_allocate(&hbThread, nullptr);
    gPollCall = thread_call_allocate(&pollThread, nullptr);
    uint64_t dl;
    char b[16];
    readVar(VAR_BOOTS, b, sizeof b);
    gBootN = parseU(b) + 1;
    snprintf(b, sizeof b, "%u", (unsigned)gBootN);
    writeVar(VAR_BOOTS, b);
    setTry("1", "Eco claimed");
    if (gTryCall) { clock_interval_to_deadline(90, kSecondScale, &dl); thread_call_enter_delayed(gTryCall, dl); }
    if (IOPMrootDomain *rd = getPMRootDomain()) gWake = rd->registerInterest(gIOGeneralInterest, &pmMsg, nullptr);
    if (OSDictionary *am = IOService::nameMatching("ACPI0003")) {
        if (IOService *ac = IOService::copyMatchingService(am)) { gAcadNote = ac->registerInterest(gIOGeneralInterest, &acadMsg, nullptr); ac->release(); }
        am->release();
    }
    if (gPollCall) { clock_interval_to_deadline(1000, kMillisecondScale, &dl); thread_call_enter_delayed(gPollCall, dl); }
    if (gDry) note("eco: RTX held away from NVRM, dry run (no power off)");
    else {
        note(gKeepBus ? "eco: RTX held away from NVRM, power off in 3 s (keepbus: nubs stay)" : "eco: RTX held away from NVRM, power off in 3 s");
        scheduleOff(3000, "claim");
    }
    return true;
}

// Stage 0 (90 s awake): record the boot as finished, clear the flag, read it back. Stage 1 (300 s): do it again, in case the
// first write was dropped. The read-back is the registry copy of /options, so it proves the write was accepted, not that it
// reached flash; gate-eco-cleared and gate-try-readback on the next boot are the proof.
static void clearNow(const char *why)
{
    char c[32];
    gClearUp = uptimeS();
    snprintf(c, sizeof c, "%u:%u:ws%d", (unsigned)gBootN, (unsigned)gClearUp, gWsSeen == 1 ? 1 : 0);
    cp(gClearedStr, c, sizeof gClearedStr);
    writeVar(VAR_CLEARED, c);
    setTry("0", why);
    readVar(VAR_TRY, gTryReadback, sizeof gTryReadback);
    IOLog("StrixDgpuGate: %s read back %s (%s)\n", VAR_TRY, gTryReadback[0] ? gTryReadback : "(none)", why);
    gCleared = true;
    if (gInfo) gInfo->publish();
}

// Evidence that userspace got to the desktop: a user client whose creator is WindowServer (it opens the framebuffer and
// accelerator user clients right after GPUWranglerWaitForPublish). One registry walk at each clear stage; written into
// strix-gpu-eco-cleared as ws0/ws1 so the next boot can tell "kernel lived 90 s" from "the desktop came up".
static bool contains(const char *s, const char *w) { for (; *s; s++) { size_t i = 0; while (w[i] && s[i] == w[i]) i++; if (!w[i]) return true; } return false; }
static int windowServerSeen()
{
    IORegistryIterator *it = IORegistryIterator::iterateOver(gIOServicePlane, kIORegistryIterateRecursively);
    if (!it) return -1;
    int seen = 0;
    for (uint32_t n = 0; n < 50000; n++) {
        IORegistryEntry *e = it->getNextObject();
        if (!e) { if (it->isValid()) break; it->reset(); continue; }   // the registry changed under the walk: start again
        if (!OSDynamicCast(IOUserClient, e)) continue;
        if (OSString *cr = OSDynamicCast(OSString, e->getProperty("IOUserClientCreator"))) if (contains(cr->getCStringNoCopy(), "WindowServer")) { seen = 1; break; }
    }
    it->release();
    return seen;
}

static uint32_t evalInt(IOACPIPlatformDevice *d, const char *name);
static IOACPIPlatformDevice *gpp9()
{
    if (!gHbGpp) { IORegistryEntry *e = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001"); gHbGpp = OSDynamicCast(IOACPIPlatformDevice, e); if (!gHbGpp && e) e->release(); }
    return gHbGpp;
}
static uint32_t rtxNubsOnBus();

static void clearTry(thread_call_param_t, thread_call_param_t)
{
    uint32_t st = gClearStage++;
    int ws = windowServerSeen();
    if (ws >= 0 && gWsSeen != 1) gWsSeen = ws;
    clearNow(st == 0 ? "clear at 90 s" : "clear again at 5 min");
    // Re-check the card: only the wake path re-ran the power-off before, but once GPP9 has no children IOPCIFamily may idle
    // it and the platform may turn PG00 back on through GPP9._PR0 / _PR3 without a sleep. Also catches re-created nubs.
    if (gHeld && !gDry) {
        gGstaRecheck = evalInt(gpp9(), "GSTA");
        uint32_t nubs = gKeepBus ? 0 : rtxNubsOnBus();
        IOLog("StrixDgpuGate: re-check (%s): GPP9.GSTA %u, RTX nubs on the bus %u, WindowServer %d\n", st == 0 ? "90 s" : "5 min", (unsigned)gGstaRecheck, (unsigned)nubs, gWsSeen);
        if (gInfo) gInfo->publish();
        if (gGstaRecheck == 1 || nubs) scheduleOff(1000, gGstaRecheck == 1 ? "re-check: GPP9 powered again" : "re-check: RTX nubs back");
    }
    if (st == 0 && gTryCall && !gStopping) { uint64_t dl; clock_interval_to_deadline(210, kSecondScale, &dl); thread_call_enter_delayed(gTryCall, dl); }
}

static IOReturn pmMsg(void *, void *, UInt32 type, IOService *, void *, vm_size_t)
{
    // A boot that got past its first clear is a good boot: write the flag again on the way out, so a lost write cannot trip the next one
    if ((type == kIOMessageSystemWillPowerOff || type == kIOMessageSystemWillRestart) && gCleared) clearNow(type == kIOMessageSystemWillRestart ? "will restart" : "will power off");
    if (type == kIOMessageSystemHasPoweredOn) scheduleOff(3000, "wake");   // a resume may bring the power resource back
    return kIOReturnSuccess;
}


static uint32_t numProp(IORegistryEntry *e, const char *k)
{
    uint32_t v = ~0u;
    if (OSData *d = OSDynamicCast(OSData, e->getProperty(k))) if (d->getLength() >= 4) memcpy(&v, d->getBytesNoCopy(), 4);
    return v;
}

static bool hasForeignChild(IOService *dev)
{
    bool any = false;
    if (OSIterator *it = dev->getChildIterator(gIOServicePlane)) {
        while (OSObject *o = it->getNextObject()) {
            IOService *c = OSDynamicCast(IOService, o);
            if (c && !c->isInactive() && (c->getState() & kIOServiceRegisteredState) && strcmp(c->getName(), "StrixDgpuClaim") != 0 && strcmp(c->getName(), "StrixDgpuAccelHold") != 0) any = true;
        }
        it->release();
    }
    return any;
}

// The firmware's own Optimus path (what Windows/Linux drive): PEGP._DSM(NVOP, func 0x1A, FLCH=1 OPCE=3) sets OMPR=3, then both
// functions go to D3hot via PMCSR, then PEGP._PS3 runs PG00._OFF. IOACPIPlatformDevice::evaluate* accepts a single NameSeg only,
// so every call is made on the owning device (GSTA on GPP9, _DSM/_PS3/_PSC on PEGP). Refuses if another driver is attached.
static uint32_t evalInt(IOACPIPlatformDevice *d, const char *name)
{
    UInt32 v = 0;
    if (!d || d->evaluateInteger(name, &v) != kIOReturnSuccess) return ~0u;
    return v;
}

static IOReturn nvopDsm(IOACPIPlatformDevice *pegp, uint32_t func, const uint8_t *arg3, size_t n, uint32_t *bitmap)
{
    static const uint8_t guid[16] = { 0xf8, 0xd8, 0x86, 0xa4, 0xda, 0x0b, 0x1b, 0x47, 0xa7, 0x2b, 0x60, 0x42, 0xa6, 0xb5, 0xbe, 0xe0 };
    static const uint8_t zero4[4] = { 0, 0, 0, 0 };
    OSObject *par[4] = { OSData::withBytes(guid, 16), OSNumber::withNumber(0x100ULL, 32), OSNumber::withNumber((unsigned long long)func, 32),
                         OSData::withBytes(arg3 ? arg3 : zero4, arg3 ? n : 4) };
    OSObject *res = nullptr;
    IOReturn r = kIOReturnNoMemory;
    if (par[0] && par[1] && par[2] && par[3]) r = pegp->evaluateObject("_DSM", &res, par, 4);
    for (OSObject *o : par) if (o) o->release();
    if (bitmap) {
        *bitmap = ~0u;
        if (OSData *d = OSDynamicCast(OSData, res)) { uint32_t b = 0; memcpy(&b, d->getBytesNoCopy(), d->getLength() < 4 ? d->getLength() : 4); *bitmap = b; }
        else if (OSNumber *nn = OSDynamicCast(OSNumber, res)) *bitmap = (uint32_t)nn->unsigned64BitValue();
    }
    if (res) res->release();
    return r;
}

// Off the bus. GPUWrangler (AppleGPUWrangler.kext) makes a GPU record for every IOPCIDevice whose class-code base class is
// 03, and GPUWranglerWaitForPublish (WindowServer, before its first framebuffer) sleeps until every record is published,
// terminated, unsupported or ejecting, for up to 60 s. A record is armed for publication only when an AGDC or an accelerator
// registers under the GPU; in Eco none ever does, so every Eco boot waited the full 60 s. A card that is powered off is gone
// from the bus as far as the OS is concerned, so its nubs are terminated: the wrangler marks the record terminated (or never
// makes one, when this runs before it starts), posts GpuRemoved and wakes the waiter. The audio function goes with it.
// The RTX functions are the IOPCIDevice children of its root port GPP9 (IOService plane; IOPCIBridge attaches every nub before
// it registers any, so this sees the audio function even while it is still matching). Returned retained, active ones only.
#define RTX_FNS 8
static uint32_t rtxNubs(IOPCIDevice **out)
{
    uint32_t n = 0;
    if (!gBridge) return 0;
    if (OSIterator *it = gBridge->getChildIterator(gIOServicePlane)) {
        while (OSObject *o = it->getNextObject()) {
            IOPCIDevice *d = OSDynamicCast(IOPCIDevice, o);
            if (!d || d->isInactive() || d->space.s.busNum != gGpuSpace.s.busNum) continue;
            if (n < RTX_FNS) { d->retain(); out[n++] = d; }
        }
        it->release();
    }
    return n;
}
static uint32_t rtxNubsOnBus() { IOPCIDevice *f[RTX_FNS]; uint32_t n = rtxNubs(f); for (uint32_t i = 0; i < n; i++) f[i]->release(); return n; }

// Called with the card off (GSTA 0, vendor 0xffff): terminate every RTX function still registered. The display function's
// GPU record is then terminated (wakes the waiter) or never made; audio goes too. Runs on every pass, not once per boot.
static void takeOffBus(IOPCIDevice **fns, uint32_t n)
{
    uint32_t done = 0;
    for (uint32_t i = 0; i < n; i++) if (!fns[i]->isInactive() && fns[i]->terminate(kIOServiceRequired)) done++;
    gOffBusTerms += done;
    gOffBus = rtxNubsOnBus() == 0;
    IOLog("StrixDgpuGate: eco: %u RTX nub(s) terminated (%u this boot), off the bus %s\n", (unsigned)done, (unsigned)gOffBusTerms, gOffBus ? "yes" : "NO");
}

static void powerOff()
{
    if (!gOffLock || gStopping) return;
    IOLockLock(gOffLock);
    gOffBusPasses++;
    IORegistryEntry *gppE = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001");
    IORegistryEntry *pegE = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001/PEGP@0");
    IOACPIPlatformDevice *gpp = OSDynamicCast(IOACPIPlatformDevice, gppE);
    IOACPIPlatformDevice *pegp = OSDynamicCast(IOACPIPlatformDevice, pegE);
    IOPCIDevice *fns[RTX_FNS];
    uint32_t nf = rtxNubs(fns);
    const char *why = nullptr;
    if (!gpp) why = "no ACPI GPP9 device";
    else if (!pegp) why = "no ACPI PEGP device";
    else if (!gBridge) why = "no PCI bridge";
    else for (uint32_t i = 0; i < nf && !why; i++) if (hasForeignChild(fns[i])) why = "another driver is attached to an RTX function";
    if (!why) {
        gGstaBefore = evalInt(gpp, "GSTA");
        if (gGstaBefore == 0) {
            gOff = true; gSta = 0; gGstaAfter = 0;
            // nubs on the bus with the card already off (a re-created nub, or firmware left it off): one fresh config read
            // confirms the link is down before terminating (no read at all when nothing is left to terminate)
            if (nf) gVendorAfter = cfg16(gGpuSpace, 0);
            note("eco: RTX already off (GPP9.GSTA 0)");
        } else {
            // the card is powered, so config space answers: (re)learn each function's address and PM capability
            for (uint32_t i = 0; i < nf; i++) {
                uint32_t cls = numProp(fns[i], "class-code") >> 16, ven = numProp(fns[i], "vendor-id") & 0xffff;
                uint8_t pm = 0;
                bool hasPm = fns[i]->findPCICapability(kIOPCIPowerManagementCapability, &pm) != 0;
                if (cls == 0x03) { gGpuSpace = fns[i]->space; if (hasPm) gGpuPm = pm; }
                else if (cls == 0x04 && ven == 0x10de) { gAudSpace = fns[i]->space; gHaveAud = true; if (hasPm) gAudPm = pm; }
            }
            uint32_t bm = 0;
            IOReturn r0 = nvopDsm(pegp, 0, nullptr, 4, &bm);
            IOLog("StrixDgpuGate: NVOP func0 -> %#x bitmap %#x (expect 0x04000001)\n", r0, bm);
            static const uint8_t a3[4] = { 0x01, 0x00, 0x00, 0x03 };   // FLCH=1, OPCE=3
            IOReturn r1 = nvopDsm(pegp, 0x1A, a3, 4, nullptr);
            // PMCSR -> D3hot; a read of 0xffff means the function does not answer: write nothing
            if (gHaveAud && gAudPm) { uint16_t v = cfg16(gAudSpace, gAudPm + 4); if (v != 0xffff) cfgW16(gAudSpace, gAudPm + 4, uint16_t((v & ~0x8003u) | 3)); }
            if (gGpuPm) { uint16_t v = cfg16(gGpuSpace, gGpuPm + 4); if (v != 0xffff) cfgW16(gGpuSpace, gGpuPm + 4, uint16_t((v & ~0x8003u) | 3)); }
            IOSleep(10);
            IOReturn r2 = pegp->evaluateObject("_PS3");
            gGstaAfter = evalInt(gpp, "GSTA");
            gPsc = evalInt(pegp, "_PSC");
            gVendorAfter = cfg16(gGpuSpace, 0);
            gSta = gGstaAfter;
            gOff = gGstaAfter == 0;
            char msg[96];
            snprintf(msg, sizeof msg, "eco: dsm0 %#x dsm1A %#x ps3 %#x gsta %u->%u psc %u vid %#x", r0, r1, r2, (unsigned)gGstaBefore, (unsigned)gGstaAfter, (unsigned)gPsc, (unsigned)gVendorAfter);
            note(msg);
        }
        // off the bus only when the firmware says off AND the display function no longer answers config reads
        if (gOff && nf && !gKeepBus) {
            if (gVendorAfter == 0xffff) takeOffBus(fns, nf);
            else IOLog("StrixDgpuGate: eco: GSTA 0 but the RTX still answers (vendor %#x): nubs kept\n", (unsigned)gVendorAfter);
        }
        if (!nf) gOffBus = true;
    }
    if (why) { char msg[96]; snprintf(msg, sizeof msg, "eco: power off refused: %s", why); note(msg); }
    for (uint32_t i = 0; i < nf; i++) fns[i]->release();
    if (gInfo) gInfo->publish();
    if (pegE) pegE->release();
    if (gppE) gppE->release();
    IOLockUnlock(gOffLock);
}

static void offThread(thread_call_param_t, thread_call_param_t) { powerOff(); }

// ---- power-source heartbeat ----------------------------------------------------------------------------------------------
// Plugging the charger in hard-hung an Eco boot (2026-11-10 09:14). To see what the card/link does around an AC change this
// samples for 20 s after every power-source event, 4 times a second, from a kernel thread call:
//   T = ms since the event, n = tick, g = GPP9.GSTA (1 powered, 0 off), v = PEGP vendor id (config read), p = PEGP PMCSR,
//   c = PEGP _PSC. Config space is not read while GSTA says off and the vendor is already known to be 0xffff; v/p/c are
//   sampled every 4th tick only. The last 8 samples go into NVRAM "strix-gpu-hb" every tick (no sync) and are committed with a
//   forced sync at the event, every strix-gpu-hb-sync ticks (default 8 = 2 s; 0 = only start and end) and at the end.
//   The last 32 samples are also published as property hb-ring for a live check.
static void hbTrigger(const char *src);
static IOReturn acadMsg(void *, void *, UInt32 type, IOService *, void *, vm_size_t)
{
    if (type == kIOACPIMessageDeviceNotification) hbTrigger("acad");
    return kIOReturnSuccess;
}

static void hbBattPoll()
{
    if (!gBatt) {
        if (OSDictionary *m = IOService::serviceMatching("AppleSmartBattery")) { gBatt = IOService::copyMatchingService(m); m->release(); }
    }
    if (gBatt) {
        OSObject *v = gBatt->getProperty("ExternalConnected");
        if (v) {
            int ac = v == kOSBooleanTrue ? 1 : 0;
            if (gBattLast >= 0 && ac != gBattLast) { gHbAc = ac; hbTrigger("batt"); }
            gBattLast = ac;
        }
    }
    uint64_t dl;
    clock_interval_to_deadline(1000, kMillisecondScale, &dl);
    if (gPollCall && !gStopping) thread_call_enter_delayed(gPollCall, dl);
}

static void hbTrigger(const char *src)
{
    if (!gHbCall || gStopping || !OSCompareAndSwap(0, 1, &gHbRunning)) return;       // a run is already sampling
    gHbEvents++;
    cp(gHbSrc, src, sizeof gHbSrc);
    if (gBatt) if (OSObject *v = gBatt->getProperty("ExternalConnected")) gHbAc = v == kOSBooleanTrue ? 1 : 0;
    char sv[8];
    gHbSync = 8;
    if (readVar("strix-gpu-hb-sync", sv, sizeof sv)) { uint32_t x = 0; for (char *c = sv; *c >= '0' && *c <= '9'; c++) x = x * 10 + (*c - '0'); gHbSync = x; }
    gHbN = 0; gHbPrev = 0; gHbT0 = mach_absolute_time();
    gHbLastG = ~0u; gHbVendor = gOff ? gVendorAfter : ~0u; gHbPmcsr = ~0u; gHbPsc = ~0u;
    gHbFlips = 0; gHbFirstFlipMs = ~0u; gHbMaxGapMs = 0;
    uint64_t dl;
    clock_interval_to_deadline(1, kMillisecondScale, &dl);
    thread_call_enter_delayed(gHbCall, dl);
}

static void hbSample()
{
    if (!gHbGpp) { IORegistryEntry *e = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001"); gHbGpp = OSDynamicCast(IOACPIPlatformDevice, e); if (!gHbGpp && e) e->release(); }
    if (!gHbPegp) { IORegistryEntry *e = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001/PEGP@0"); gHbPegp = OSDynamicCast(IOACPIPlatformDevice, e); if (!gHbPegp && e) e->release(); }
    uint64_t now = mach_absolute_time(), ns;
    absolutetime_to_nanoseconds(now - gHbT0, &ns);
    uint32_t ms = (uint32_t)(ns / 1000000ULL);
    uint32_t n = gHbN++;
    if (gHbPrev) { uint64_t d; absolutetime_to_nanoseconds(now - gHbPrev, &d); uint32_t gap = (uint32_t)(d / 1000000ULL); if (gap > gHbMaxGapMs) gHbMaxGapMs = gap; }
    gHbPrev = now;

    uint32_t g = evalInt(gHbGpp, "GSTA");
    if (n && gHbLastG != ~0u && g != ~0u && g != gHbLastG) { gHbFlips++; if (g == 1 && gHbFirstFlipMs == ~0u) gHbFirstFlipMs = ms; }
    gHbLastG = g;
    bool deadKnown = g == 0 && gHbVendor == 0xffff;                       // never read config of a link known to be down
    if (n % 4 == 0) {
        if (!deadKnown && gBridge) {
            gHbVendor = cfg16(gGpuSpace, 0);
            gHbPmcsr = (gHbVendor != 0xffff && gGpuPm) ? cfg16(gGpuSpace, gGpuPm + 4) : ~0u;
        }
        gHbPsc = evalInt(gHbPegp, "_PSC");
    }
    char buf[44];
    char v[8] = "-", pm[8] = "-", pc[8] = "-";
    if (gHbVendor != ~0u) snprintf(v, sizeof v, "%04x", (unsigned)gHbVendor);
    if (gHbPmcsr != ~0u) snprintf(pm, sizeof pm, "%04x", (unsigned)gHbPmcsr);
    if (gHbPsc != ~0u) snprintf(pc, sizeof pc, "%u", (unsigned)gHbPsc);
    snprintf(buf, sizeof buf, "T%u n%u g%d v%s p%s c%s", (unsigned)ms, (unsigned)n, g == ~0u ? -1 : (int)g, v, pm, pc);
    cp(gRing[gRingN % HB_RING], buf, sizeof gRing[0]);
    gRingN++;
    gHbLastN = n + 1;

    // NVRAM: last 8 samples in one variable
    char line[8 * 44 + 40];
    snprintf(line, sizeof line, "ev%u %s ac%d ", (unsigned)gHbEvents, gHbSrc, gHbAc);
    size_t len = strlen(line);
    uint32_t cnt = gRingN < 8 ? gRingN : 8;
    for (uint32_t i = 0; i < cnt && len + 46 < sizeof line; i++) {
        uint32_t idx = (gRingN - cnt + i) % HB_RING;
        snprintf(line + len, sizeof line - len, "%s;", gRing[idx]);
        len = strlen(line);
    }
    bool last = n + 1 >= HB_TICKS;
    bool sync = n == 0 || last || (gHbSync && n % gHbSync == 0);
    writeVar("strix-gpu-hb", line, sync);
    if (gInfo) { gInfo->publish(); gInfo->publishRing(); }

    if (last || gStopping) { OSCompareAndSwap(1, 0, &gHbRunning); return; }
    uint64_t dl;
    clock_interval_to_deadline(250, kMillisecondScale, &dl);
    thread_call_enter_delayed(gHbCall, dl);
}

static void hbThread(thread_call_param_t, thread_call_param_t) { hbSample(); }
static void pollThread(thread_call_param_t, thread_call_param_t) { hbBattPoll(); }

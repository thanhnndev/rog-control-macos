// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
//
// StrixDgpuGate 0.1.0: "Eco" for the RTX 5060 on the GA403WM under macOS Tahoe 26 (Darwin 25.x).
//
// The NullMoth NVIDIA stack (NVRM and the kexts that sit on it) binds the RTX at boot and has no runtime power management,
// so the card can only be powered off when NVRM never attached to it. StrixDgpuClaim matches the RTX with a higher probe
// score than NVRM (2000 vs 1000). Its probe() says yes only when the stored GPU mode asks for Eco; then NVRM, NVRMFB,
// NVAccel and NVRMAGDC never start, and this driver moves the card to D3hot and runs \_SB.PCI0.GPP9.PG00._OFF.
// In every other case probe() returns null and NVRM binds as if this kext did not exist.
//
//   NVRAM  strix-gpu-mode = standard | eco | optimized   written by AsusWmi (ABI 6); optimized = Eco only when the boot
//                                                        starts on battery (ACPI0003._PSR == 0), decided once, here
//   NVRAM  strix-gpu-eco-try = 1                          set when Eco is claimed, cleared after 90 s of uptime. Still 1 at
//                                                        the next probe = the last Eco boot did not finish: stand down once
//   boot-args  -strixgate_off      never claim (recovery)
//              strixgate_dry=1     claim the card (NVRM stays off) but do not power it off: first-install test
//
// Properties of the IOResources service StrixDgpuGate (read by AsusWmi): gate-effective (0 standard, 1 eco),
// gate-held, gate-powered-off, gate-tripped, pg00-sta, gate-state (text).
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <kern/thread_call.h>
#include <libkern/version.h>
#include <kern/clock.h>
#include <libkern/OSAtomic.h>
#include <string.h>

#define VAR_MODE "strix-gpu-mode"
#define VAR_TRY  "strix-gpu-eco-try"

static void cp(char *d, const char *s, size_t n) { size_t i = 0; for (; i + 1 < n && s[i]; i++) d[i] = s[i]; d[i] = 0; }
static bool gHeld, gOff, gTripped, gDry;
static int gEffective = 0;
static uint32_t gSta = ~0u, gGstaBefore = ~0u, gGstaAfter = ~0u, gPsc = ~0u, gVendorAfter = ~0u;
static char gState[96] = "not probed";
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
    void stop(IOService *provider) override { gInfo = nullptr; IOService::stop(provider); }
    void publish()
    {
        setProperty("gate-effective", (unsigned long long)gEffective, 32);
        setProperty("gate-held", gHeld);
        setProperty("gate-powered-off", gOff);
        setProperty("gate-tripped", gTripped);
        if (gSta != ~0u) setProperty("pg00-sta", (unsigned long long)gSta, 32);
        if (gGstaBefore != ~0u) setProperty("gsta-before", (unsigned long long)gGstaBefore, 32);
        if (gGstaAfter != ~0u) setProperty("gsta-after", (unsigned long long)gGstaAfter, 32);
        if (gPsc != ~0u) setProperty("psc", (unsigned long long)gPsc, 32);
        if (gVendorAfter != ~0u) setProperty("vendor-after", (unsigned long long)gVendorAfter, 32);
        setProperty("gate-state", gState);
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

// ---- the claim -----------------------------------------------------------------------------------------------------------
class StrixDgpuClaim : public IOService {
    OSDeclareDefaultStructors(StrixDgpuClaim)
public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    thread_call_t offCall = nullptr, tryCall = nullptr;
    IONotifier *wake = nullptr;
    IOPCIDevice *gpu = nullptr;
    // heartbeat
    thread_call_t hbCall = nullptr, pollCall = nullptr;
    IONotifier *acadNote = nullptr;
    IOACPIPlatformDevice *hbGpp = nullptr, *hbPegp = nullptr;
    IOService *batt = nullptr;
    int battLast = -1;
    uint8_t pmCap = 0;
    bool pmCapDone = false;
    uint64_t hbT0 = 0, hbPrev = 0;
    uint32_t hbN = 0, hbSync = 8, hbLastG = ~0u, hbVendor = ~0u, hbPmcsr = ~0u, hbPsc = ~0u;
    void hbTrigger(const char *src);
    void hbSample();
    void hbBattPoll();
    static void hbThread(thread_call_param_t self, thread_call_param_t) { static_cast<StrixDgpuClaim *>(self)->hbSample(); }
    static void pollThread(thread_call_param_t self, thread_call_param_t) { static_cast<StrixDgpuClaim *>(self)->hbBattPoll(); }
    static IOReturn acadMsg(void *target, void *ref, UInt32 type, IOService *, void *, vm_size_t);
    static void offThread(thread_call_param_t self, thread_call_param_t);
    static void clearTry(thread_call_param_t, thread_call_param_t) { writeVar(VAR_TRY, "0"); }
    static IOReturn pmMsg(void *target, void *ref, UInt32 type, IOService *, void *, vm_size_t);
    void powerOff();
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
    if (tr[0] == '1') {          // the previous Eco boot never reached 90 s of uptime: let NVRM have the card this once
        gTripped = true;
        writeVar(VAR_TRY, "0");
        note("standard: loop guard (previous Eco boot did not finish)");
        return false;
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

bool StrixDgpuClaim::start(IOService *provider)
{
    if (!IOService::start(provider)) return false;
    gpu = OSDynamicCast(IOPCIDevice, provider);
    if (!gpu) return false;
    gpu->retain();
    gHeld = true; gEffective = 1;
    uint32_t dry = 0;
    gDry = PE_parse_boot_argn("strixgate_dry", &dry, sizeof dry) && dry == 1;
    writeVar(VAR_TRY, "1");
    offCall = thread_call_allocate(&StrixDgpuClaim::offThread, this);
    tryCall = thread_call_allocate(&StrixDgpuClaim::clearTry, this);
    uint64_t dl;
    if (tryCall) { clock_interval_to_deadline(90, kSecondScale, &dl); thread_call_enter_delayed(tryCall, dl); }
    if (IOPMrootDomain *rd = getPMRootDomain()) wake = rd->registerInterest(gIOGeneralInterest, &StrixDgpuClaim::pmMsg, this);
    hbCall = thread_call_allocate(&StrixDgpuClaim::hbThread, this);
    pollCall = thread_call_allocate(&StrixDgpuClaim::pollThread, this);
    if (OSDictionary *am = IOService::nameMatching("ACPI0003")) {
        if (IOService *ac = IOService::copyMatchingService(am)) { acadNote = ac->registerInterest(gIOGeneralInterest, &StrixDgpuClaim::acadMsg, this); ac->release(); }
        am->release();
    }
    if (pollCall) { clock_interval_to_deadline(1000, kMillisecondScale, &dl); thread_call_enter_delayed(pollCall, dl); }
    if (gDry) note("eco: RTX held away from NVRM, dry run (no power off)");
    else {
        note("eco: RTX held away from NVRM, power off in 3 s");
        if (offCall) { clock_interval_to_deadline(3, kSecondScale, &dl); thread_call_enter_delayed(offCall, dl); }
    }
    return true;
}

void StrixDgpuClaim::stop(IOService *provider)
{
    if (wake) { wake->remove(); wake = nullptr; }
    if (acadNote) { acadNote->remove(); acadNote = nullptr; }
    if (pollCall) { thread_call_cancel_wait(pollCall); thread_call_free(pollCall); pollCall = nullptr; }
    if (hbCall) { thread_call_cancel_wait(hbCall); thread_call_free(hbCall); hbCall = nullptr; }
    if (hbGpp) { hbGpp->release(); hbGpp = nullptr; }
    if (hbPegp) { hbPegp->release(); hbPegp = nullptr; }
    if (batt) { batt->release(); batt = nullptr; }
    if (offCall) { thread_call_cancel_wait(offCall); thread_call_free(offCall); offCall = nullptr; }
    if (tryCall) { thread_call_cancel_wait(tryCall); thread_call_free(tryCall); tryCall = nullptr; }
    if (gpu) { gpu->release(); gpu = nullptr; }
    IOService::stop(provider);
}

IOReturn StrixDgpuClaim::pmMsg(void *target, void *, UInt32 type, IOService *, void *, vm_size_t)
{
    StrixDgpuClaim *me = static_cast<StrixDgpuClaim *>(target);
    if (type == kIOMessageSystemHasPoweredOn && gHeld && !gDry && me->offCall) {   // a resume may bring the power resource back
        uint64_t dl;
        clock_interval_to_deadline(3, kSecondScale, &dl);
        thread_call_enter_delayed(me->offCall, dl);
    }
    return kIOReturnSuccess;
}

void StrixDgpuClaim::offThread(thread_call_param_t self, thread_call_param_t) { static_cast<StrixDgpuClaim *>(self)->powerOff(); }

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

void StrixDgpuClaim::powerOff()
{
    IORegistryEntry *gppE = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001");
    IORegistryEntry *pegE = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001/PEGP@0");
    IOACPIPlatformDevice *gpp = OSDynamicCast(IOACPIPlatformDevice, gppE);
    IOACPIPlatformDevice *pegp = OSDynamicCast(IOACPIPlatformDevice, pegE);
    IOPCIDevice *aud = nullptr;
    if (OSDictionary *m = IOService::serviceMatching("IOPCIDevice")) {
        if (OSIterator *it = IOService::getMatchingServices(m)) {
            while (OSObject *o = it->getNextObject()) {
                IOPCIDevice *d = OSDynamicCast(IOPCIDevice, o);
                if (d && (numProp(d, "vendor-id") & 0xffff) == 0x10de && (numProp(d, "class-code") >> 16) == 0x04 && !aud) { aud = d; aud->retain(); }
            }
            it->release();
        }
        m->release();
    }
    const char *why = nullptr;
    if (!gpp) why = "no ACPI GPP9 device";
    else if (!pegp) why = "no ACPI PEGP device";
    else if (hasForeignChild(gpu)) why = "another driver is attached to the RTX";
    else if (aud && hasForeignChild(aud)) why = "a driver is attached to the RTX audio function";
    else {
        gGstaBefore = evalInt(gpp, "GSTA");
        if (gGstaBefore == 0) { gOff = true; gSta = 0; gGstaAfter = 0; note("eco: RTX already off (GPP9.GSTA 0)"); }
        else {
            uint32_t bm = 0;
            IOReturn r0 = nvopDsm(pegp, 0, nullptr, 4, &bm);
            IOLog("StrixDgpuGate: NVOP func0 -> %#x bitmap %#x (expect 0x04000001)\n", r0, bm);
            static const uint8_t a3[4] = { 0x01, 0x00, 0x00, 0x03 };   // FLCH=1, OPCE=3
            IOReturn r1 = nvopDsm(pegp, 0x1A, a3, 4, nullptr);
            IOPCIDevice *fns[2] = { aud, gpu };
            for (IOPCIDevice *d : fns) {
                uint8_t pm = 0;
                if (d && d->findPCICapability(kIOPCIPowerManagementCapability, &pm) && pm) {
                    uint16_t v = d->configRead16(pm + 4);
                    d->configWrite16(pm + 4, uint16_t((v & ~0x8003u) | 3));
                }
            }
            IOSleep(10);
            IOReturn r2 = pegp->evaluateObject("_PS3");
            gGstaAfter = evalInt(gpp, "GSTA");
            gPsc = evalInt(pegp, "_PSC");
            gVendorAfter = gpu->configRead16(0);
            gSta = gGstaAfter;
            gOff = gGstaAfter == 0;
            char msg[96];
            snprintf(msg, sizeof msg, "eco: dsm0 %#x dsm1A %#x ps3 %#x gsta %u->%u psc %u vid %#x", r0, r1, r2, (unsigned)gGstaBefore, (unsigned)gGstaAfter, (unsigned)gPsc, (unsigned)gVendorAfter);
            note(msg);
        }
    }
    if (why) { char msg[96]; snprintf(msg, sizeof msg, "eco: power off refused: %s", why); note(msg); }
    if (gInfo) gInfo->publish();
    if (aud) aud->release();
    if (pegE) pegE->release();
    if (gppE) gppE->release();
}


// ---- power-source heartbeat ----------------------------------------------------------------------------------------------
// Plugging the charger in hard-hung an Eco boot (2026-11-10 09:14). To see what the card/link does around an AC change this
// samples for 20 s after every power-source event, 4 times a second, from a kernel thread call:
//   T = ms since the event, n = tick, g = GPP9.GSTA (1 powered, 0 off), v = PEGP vendor id (config read), p = PEGP PMCSR,
//   c = PEGP _PSC. Config space is not read while GSTA says off and the vendor is already known to be 0xffff; v/p/c are
//   sampled every 4th tick only. The last 8 samples go into NVRAM "strix-gpu-hb" every tick (no sync) and are committed with a
//   forced sync at the event, every strix-gpu-hb-sync ticks (default 8 = 2 s; 0 = only start and end) and at the end.
//   The last 32 samples are also published as property hb-ring for a live check.
IOReturn StrixDgpuClaim::acadMsg(void *target, void *, UInt32 type, IOService *, void *, vm_size_t)
{
    if (type == kIOACPIMessageDeviceNotification) static_cast<StrixDgpuClaim *>(target)->hbTrigger("acad");
    return kIOReturnSuccess;
}

void StrixDgpuClaim::hbBattPoll()
{
    if (!batt) {
        if (OSDictionary *m = IOService::serviceMatching("AppleSmartBattery")) { batt = IOService::copyMatchingService(m); m->release(); }
    }
    if (batt) {
        OSObject *v = batt->getProperty("ExternalConnected");
        if (v) {
            int ac = v == kOSBooleanTrue ? 1 : 0;
            if (battLast >= 0 && ac != battLast) { gHbAc = ac; hbTrigger("batt"); }
            battLast = ac;
        }
    }
    uint64_t dl;
    clock_interval_to_deadline(1000, kMillisecondScale, &dl);
    if (pollCall) thread_call_enter_delayed(pollCall, dl);
}

void StrixDgpuClaim::hbTrigger(const char *src)
{
    if (!hbCall || !OSCompareAndSwap(0, 1, &gHbRunning)) return;       // a run is already sampling
    gHbEvents++;
    cp(gHbSrc, src, sizeof gHbSrc);
    if (batt) if (OSObject *v = batt->getProperty("ExternalConnected")) gHbAc = v == kOSBooleanTrue ? 1 : 0;
    char sv[8];
    hbSync = 8;
    if (readVar("strix-gpu-hb-sync", sv, sizeof sv)) { uint32_t x = 0; for (char *c = sv; *c >= '0' && *c <= '9'; c++) x = x * 10 + (*c - '0'); hbSync = x; }
    hbN = 0; hbPrev = 0; hbT0 = mach_absolute_time();
    hbLastG = ~0u; hbVendor = gOff ? gVendorAfter : ~0u; hbPmcsr = ~0u; hbPsc = ~0u;
    gHbFlips = 0; gHbFirstFlipMs = ~0u; gHbMaxGapMs = 0;
    uint64_t dl;
    clock_interval_to_deadline(1, kMillisecondScale, &dl);
    thread_call_enter_delayed(hbCall, dl);
}

void StrixDgpuClaim::hbSample()
{
    if (!hbGpp) { IORegistryEntry *e = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001"); hbGpp = OSDynamicCast(IOACPIPlatformDevice, e); if (!hbGpp && e) e->release(); }
    if (!hbPegp) { IORegistryEntry *e = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001/PEGP@0"); hbPegp = OSDynamicCast(IOACPIPlatformDevice, e); if (!hbPegp && e) e->release(); }
    uint64_t now = mach_absolute_time(), ns;
    absolutetime_to_nanoseconds(now - hbT0, &ns);
    uint32_t ms = (uint32_t)(ns / 1000000ULL);
    uint32_t n = hbN++;
    if (hbPrev) { uint64_t d; absolutetime_to_nanoseconds(now - hbPrev, &d); uint32_t gap = (uint32_t)(d / 1000000ULL); if (gap > gHbMaxGapMs) gHbMaxGapMs = gap; }
    hbPrev = now;

    uint32_t g = evalInt(hbGpp, "GSTA");
    if (n && hbLastG != ~0u && g != ~0u && g != hbLastG) { gHbFlips++; if (g == 1 && gHbFirstFlipMs == ~0u) gHbFirstFlipMs = ms; }
    hbLastG = g;
    bool deadKnown = g == 0 && hbVendor == 0xffff;                       // never read config of a link known to be down
    if (n % 4 == 0) {
        if (!deadKnown && gpu) {
            hbVendor = gpu->configRead16(0);
            if (!pmCapDone) { pmCapDone = true; uint8_t pm = 0; if (gpu->findPCICapability(kIOPCIPowerManagementCapability, &pm)) pmCap = pm; }
            hbPmcsr = (hbVendor != 0xffff && pmCap) ? gpu->configRead16(pmCap + 4) : ~0u;
        }
        hbPsc = evalInt(hbPegp, "_PSC");
    }
    char buf[44];
    char v[8] = "-", pm[8] = "-", pc[8] = "-";
    if (hbVendor != ~0u) snprintf(v, sizeof v, "%04x", (unsigned)hbVendor);
    if (hbPmcsr != ~0u) snprintf(pm, sizeof pm, "%04x", (unsigned)hbPmcsr);
    if (hbPsc != ~0u) snprintf(pc, sizeof pc, "%u", (unsigned)hbPsc);
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
    bool sync = n == 0 || last || (hbSync && n % hbSync == 0);
    writeVar("strix-gpu-hb", line, sync);
    if (gInfo) { gInfo->publish(); gInfo->publishRing(); }

    if (last) { OSCompareAndSwap(1, 0, &gHbRunning); return; }
    uint64_t dl;
    clock_interval_to_deadline(250, kMillisecondScale, &dl);
    thread_call_enter_delayed(hbCall, dl);
}

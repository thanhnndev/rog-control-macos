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
#include <string.h>

#define VAR_MODE "strix-gpu-mode"
#define VAR_TRY  "strix-gpu-eco-try"

static void cp(char *d, const char *s, size_t n) { size_t i = 0; for (; i + 1 < n && s[i]; i++) d[i] = s[i]; d[i] = 0; }
static bool gHeld, gOff, gTripped, gDry;
static int gEffective = 0;
static uint32_t gSta = ~0u;
static char gState[96] = "not probed";
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

static void writeVar(const char *k, const char *val)        // from a kernel thread only
{
    IORegistryEntry *o = opts();
    if (!o) return;
    if (OSString *s = OSString::withCString(val)) { o->setProperty(k, s); s->release(); }
    if (OSString *key = OSString::withCString(k)) { o->setProperty("IONVRAM-FORCESYNCNOW-PROPERTY", key); key->release(); }
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
        setProperty("gate-state", gState);
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

// PMCSR D3hot on both functions, then PG00._OFF (Linux runtime D3cold order). Refuses if any other driver is on either function.
void StrixDgpuClaim::powerOff()
{
    IORegistryEntry *gppE = IORegistryEntry::fromPath("IOACPIPlane:/_SB/PCI0@0/GPP9@30001");
    IOACPIPlatformDevice *gpp = OSDynamicCast(IOACPIPlatformDevice, gppE);
    auto sta = [&]() -> uint32_t {
        UInt32 v = 0xff;
        if (!gpp) return ~0u;
        if (gpp->evaluateInteger("\\_SB.PCI0.GPP9.PG00._STA", &v) != kIOReturnSuccess && gpp->evaluateInteger("PG00._STA", &v) != kIOReturnSuccess) return ~0u;
        return v;
    };
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
    else if (hasForeignChild(gpu)) why = "another driver is attached to the RTX";
    else if (aud && hasForeignChild(aud)) why = "a driver is attached to the RTX audio function";
    else if (sta() == 0) { gOff = true; gSta = 0; note("eco: RTX already off (PG00._STA 0)"); }
    else {
        IOPCIDevice *fns[2] = { aud, gpu };
        for (IOPCIDevice *d : fns) {
            uint8_t pm = 0;
            if (d && d->findPCICapability(kIOPCIPowerManagementCapability, &pm) && pm) {
                uint16_t v = d->configRead16(pm + 4);
                d->configWrite16(pm + 4, uint16_t((v & ~0x8003u) | 3));
            }
        }
        IOSleep(10);
        IOReturn r = gpp->evaluateObject("\\_SB.PCI0.GPP9.PG00._OFF");
        if (r != kIOReturnSuccess) r = gpp->evaluateObject("PG00._OFF");
        gSta = sta();
        gOff = gSta == 0;
        char msg[96];
        snprintf(msg, sizeof msg, "eco: PG00._OFF %#x, PG00._STA %u (0 = off)", r, (unsigned)gSta);
        note(msg);
    }
    if (why) { char msg[96]; snprintf(msg, sizeof msg, "eco: power off refused: %s", why); note(msg); }
    if (gInfo) gInfo->publish();
    if (aud) aud->release();
    if (gppE) gppE->release();
}

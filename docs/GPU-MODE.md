# GPU mode (Eco / Standard / Optimized) on the GA403WM, macOS 26

Status: StrixDgpuGate 8b33c13 verified live (boot 2026-11-09 13:06: dsm0 0, dsm1A 0, ps3 0, GSTA 1->0, PSC 3, vendor 0xFFFF, no panic, 890M fine). AsusWmi 0.3.0 (ABI 6) and RogControl 0.6.0 are built, not installed.

## Mechanism
The NullMoth NVIDIA stack (NVRM 2.7.1, NVRMFB, NVAccel, NVRMAGDC) binds the RTX at boot and has no runtime power
management, so the card can only be powered off if NVRM never attached. Therefore **every mode change takes effect at the
next boot**; there is no live switch.

* Stored mode: NVRAM `strix-gpu-mode` = `standard` | `eco` | `optimized` (absent = standard). Written by AsusWmi from a kernel
  thread (`debug.asuswmi.gpu_mode` or user client selector 7), flushed with `IONVRAM-FORCESYNCNOW-PROPERTY`.
* `StrixDgpuClaim` (new kext StrixDgpuGate 0.1.0) matches the RTX (10de, class 03) with `IOProbeScore` 2000 (NVRM: 1000).
  `probe()` returns null (NVRM binds as if the kext were absent) unless: Darwin 25.x, no `-strixgate_off`, mode is `eco`, or
  `optimized` and `ACPI0003._PSR == 0` at boot (unknown power source => standard), and the loop guard is clear.
* When it claims: NVRM and everything above it never start. After 3 s it puts the RTX and its audio function in D3hot (PMCSR)
  and runs the firmware Optimus path: PEGP `_DSM` (NVOP GUID, func 0x1A, Arg3 01 00 00 03 sets OMPR=3), PMCSR D3hot on both functions, PEGP `_PS3` (which runs PG00._OFF); re-run after wake if GPP9.GSTA reads 1. Published: `gsta-before`, `gsta-after`, `psc`, `vendor-after`, refusing if any other driver
  sits on either function. After a system wake it re-checks and repeats.
* `StrixDgpuAccelHold` (IOMatchCategory IOAccelerator, score 1000) takes NVAccel's category in Eco and never registers, so NVAccel's 30 s wait for NVRM never starts. The Eco decision (incl. loop guard) is made once per boot, on the first probe of any personality.
* Eco never uses `-nvoff` or `nullmoth-remove` (those park NMXGPU/NMXAGDC too).
* Status service `StrixDgpuGate` (IOResources): `gate-effective`, `gate-held`, `gate-powered-off`, `gate-tripped`, `pg00-sta`, `gate-state`.
* AsusWmi ABI 6: selector 6 `GpuGet` (8 words: flags, stored mode, boot mode, DSTS 0x00090020 / 0x00090016, PG00 _STA, Darwin
  major), selector 7 `GpuSet` { what, value }: 1 = store mode (always allowed on Darwin 25), 2 = WMI dGPU disable, 3 = MUX.
  Gate is `version_major == 25` (all of macOS 26), not a build.
* RogControl 0.6.0: "GPU mode" tile (Eco, Standard, Optimized, Ultimate disabled). "Restart required" shows when the boot
  mode differs from the wanted mode for the current power source. Only the window reads GPU state (no read in the popover or
  on AC change); AC-change handling is untouched.

## Why WMI 0x00090020 is not the Eco path
DSDT WMNB `DEVS 0x00090020`=1 runs `EC.PREC=1`, `Notify(PEGP,0x81)`, **`Notify(PEGP,0x03)` (eject request)**, waits `WAT1`
(up to 15 s) and sets `EC.PWMD=0` (cuts the card's rail); 0 does the reverse. That would pull power under NVRM, and the EC state
survives a warm reboot, so a later Standard boot could find the card unpowered. `ASUS_GPU_SET_DGPU` therefore is allowed only
when the RTX is provably held by the gate and has no other driver (`ASUS_GPF_LIVE_OK`); the app never calls it. MUX
(`0x00090016`) set needs boot-arg `asuswmi_mux=1`; it would hand the panel to the RTX while WindowServer runs on the 890M. Ultimate is
disabled in the UI.

## Failure modes
* IOACPIPlatformDevice evaluate* rejects dotted paths (kIOReturnBadArgument, seen on the first real boot): every call is a single NameSeg on the owning device (GSTA on GPP9; _DSM/_PS3/_PSC on PEGP). Power-off itself is still untested end to end: a hang or panic is possible.  (StrixS0ix 0.1.16 same path, also not installed): a hang or panic is possible. Guard: Eco claim sets
  `strix-gpu-eco-try=1`, cleared after 90 s; if still 1 at the next boot the gate stands down once (RTX to NVRM) and reports `gate-tripped`. A normal
  shutdown within 90 s of an Eco boot also trips it (safe direction).
* Gate kext missing/not loaded: Eco is stored but has no effect; the app warns and shows "StrixDgpuGate not loaded".
* NVRAM write refused/not persisted (OpenCore emulated NVRAM without LegacySchema): app shows the old mode after re-read.
  Other kexts already persist plain-named vars (`nmxgpu-stage`), so native NVRAM is assumed.
* HDMI is wired to the RTX: unavailable in Eco.
* Optimized does not switch on AC change; it shows "restart required" instead.

## Undo / recovery
* App: choose Standard, restart. Or `sudo nvram -d strix-gpu-mode` / `sudo nvram strix-gpu-mode=standard`, or `debug.asuswmi.gpu_mode=0`.
* Boot-arg `-strixgate_off` (OpenCore picker, no ESP edit needed to test) forces NVRM; OpenCore "Reset NVRAM" also clears the mode.
* Remove StrixDgpuGate.kext: NVRM binds as before.
* First install test: boot-arg `strixgate_dry=1` claims the card (NVRM stays off) without powering it off.

## Sleep / wake with the RTX off (code review, not tested)

State seen live with the RTX off: PEGP and HDAU IOPCIDevice nodes report PM CurrentPowerState 2 of 3 (IOPCIFamily still thinks the
functions are on); GPP9 PEGP firmware state is `_PSC 3`, `DGPS 1`, `OMPR 2`; `PG00` is off (`GSTA 0`).

What happens (from the DSDT; IOPCIFamily source was not available, so its part is an expectation to confirm by trace):
* System sleep: IOPCIFamily saves config space of PEGP/HDAU (reads 0xFFFF) and writes PMCSR D3 (dropped, no link). Harmless as long as the
  save is not used as truth. On wake it restores the saved values: writes to an absent device are dropped.
* Risk A (main one): if the PM tree ever drives PEGP back to D0 through ACPI, `PEGP._PS0` runs because `DGPS != 0`, and that calls
  `PG00._ON`: the RTX powers up behind the gate (rail on, link trained, config restore races). The gate then sees GSTA 1.
* Risk B: the firmware `_WAK`/EC path could re-enable the rail (EC `VGAT`) on wake; same visible symptom as A (GSTA 1).
* Gate behaviour today: `kIOMessageSystemHasPoweredOn` schedules `powerOff()` after 3 s; it reads GSTA, skips if 0, else repeats
  `_DSM 0x1A` -> D3hot -> `_PS3`. That covers A and B. It does not need `WillSleep`: the card is already off, and powering a card off
  just before sleep adds a second ACPI transition inside the sleep window for no gain.
* Gate weak spots to fix (small, not built yet):
  1. `offCall` is not `THREAD_CALL_OPTIONS_ONCE`: two wake messages (dark wake then full wake) can run `powerOff()` concurrently.
     Allocate with `thread_call_allocate_with_options(..., THREAD_CALL_OPTIONS_ONCE)`.
  2. `powerOff()` overwrites `gsta-before` with 0 on a no-op wake; keep the first-boot trace in `gsta-boot` and add a `wake-count`
     and `gsta-wake` (GSTA seen at the last wake) so a trace shows whether A/B happened.
  3. If the re-off after wake fails (GSTA still 1), the card stays on and `gate-powered-off` is false: the app already shows
     "power-off pending"; also log it (`wake re-off failed`).
* Risks that stay: a wake where the EC cut the rail while `GSTA` still says 1 (stale) would make `_DSM`/`_PS3` run on a dead card:
  the `_PS3` is guarded by `GSTA` inside `PG00._OFF`, so it returns without touching the rail.
* Test (owner starts): `ioreg -c StrixDgpuGate` before and after one sleep: `gate-powered-off Yes`, `pg00-sta 0`, `vendor-after`; then
  `log show --predicate 'eventMessage contains "StrixDgpuGate"'` for the wake line.

## AC-change heartbeat (trace instrumentation, StrixDgpuGate)

Why: plugging the charger in hard-hung an Eco boot 8 s after AC came in (2026-11-10 09:14), no panic. Cause not proven.

* Triggers (Eco claim only): Notify on ACAD (ACPI0003, `kIOACPIMessageDeviceNotification`) and a 1 Hz poll of `AppleSmartBattery.ExternalConnected`
  (a registry property read, no AML). `kIOPMMessageSystemPowerEventOccurred` is a thermal message, not used. First source wins, shown in `hb-src`.
* Run: 80 ticks x 250 ms. Per tick: ms since event, tick n, GPP9 `GSTA` (every tick), PEGP vendor id + PMCSR (config reads) and `_PSC` every 4th
  tick. No config read while GSTA = 0 and the vendor is already 0xffff.
* NVRAM `strix-gpu-hb`: one variable, rewritten every tick with the last 8 samples (no sync). Forced sync at the event, every
  `strix-gpu-hb-sync` ticks (NVRAM var, default 8 = 2 s, 0 = only start and end) and at the end.
  Survival: without the forced sync the write stays in the in-memory NVRAM image and a hard hang loses it; the forced sync is the same
  call the loop guard uses and it survived a forced restart. So after a hang you get the last synced window (up to 2 s old). If the forced sync
  itself were the stall, set `strix-gpu-hb-sync=0` (event + end only) and compare. A RAM buffer does not survive a power-button restart.
* Live properties on the IOResources service: `hb-ring` (last 32 samples), `hb-events`, `hb-src`, `hb-ac`, `hb-ticks`, `hb-gsta-flips`,
  `hb-first-flip-ms` (ms after the event when GSTA first went 0 -> 1: the EC/SMU re-power hypothesis), `hb-max-gap-ms` (largest gap between
  ticks: a stall detector).
* Does the EC flip GSTA on its own? By the AML: `GSTA` reads a chipset root-port bit (`M009(REST)` at NBIO `M084+0x1502`), the
  bridge reset line that `BPGN/POFF` drive, not an EC register. The EC only switches the rail (`VGAT`). So GSTA 0 -> 1 means the chipset
  side re-released the reset, not just the EC; `hb-first-flip-ms` will tell. Not observable from the DSL alone.

## Install batch (for the main session, after owner OK)
Builds (this tree, `MACKERNELSDK=…/ga403wm-hackintosh/build/MacKernelSDK scripts/build.sh AsusWmi StrixDgpuGate`, `scripts/build-rogcontrol.sh`):
* StrixDgpuGate 8b33c13: UUID D48A1ED0-8111-33B7-AEDB-4EF1113343C8 (already installed, OC Kernel Add #47)
* AsusWmi 0.3.0 ABI 6: UUID 42C34ABF-6887-31BE-8FF5-9A9E0096C6EB (executable sha256 84e2a660…687b)
* RogControl 0.6.0 (ad-hoc signed, x86_64)

Steps:
1. `scripts/macos-install-kext.sh AsusWmi` (backs the old kext up to `EFI/OC/Kexts-backup`; config.plist untouched, it already lists AsusWmi).
   Undo: `scripts/macos-install-kext.sh --undo AsusWmi`.
2. `scripts/build-rogcontrol.sh --install` (copies to /Applications, restarts the LaunchAgent). Undo: reinstall rogcontrol-v0.5.3.
3. Reboot once. Check: `sysctl debug.asuswmi.status` shows `gpu_mode`, the app GPU tile reads "Now: RTX off" with Eco selected and no
   "Restart required".

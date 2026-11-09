# GPU mode (Eco / Standard / Optimized) on the GA403WM, macOS 26

Status: built, **not installed or booted**. Needs one reboot to test (see "Install batch").

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
  and evaluates `\_SB.PCI0.GPP9.PG00._OFF` (same sequence as StrixS0ix 0.1.16 `s0ix_dgpuoff`), refusing if any other driver
  sits on either function. After a system wake it re-checks and repeats.
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
* PG00._OFF untested on macOS (StrixS0ix 0.1.16 same path, also not installed): a hang or panic is possible. Guard: Eco claim sets
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

## Install batch (for the main session, after owner OK)
1. `build/AsusWmi.kext` (0.3.0, ABI 6) and `build/StrixDgpuGate.kext` (0.1.0) via `scripts/build.sh AsusWmi StrixDgpuGate`
   (`MACKERNELSDK=…/ga403wm-hackintosh/build/MacKernelSDK`), RogControl.app via `scripts/build-rogcontrol.sh`.
2. Reboot once with Standard stored (no behaviour change; verify AsusWmi ABI 6, `ioreg -c StrixDgpuGate`).
3. Set Eco in the app, optionally add `strixgate_dry=1` first, reboot: expect `gate-held`, no NVRM; then without dry: `gate-powered-off`, `pg00-sta 0`.

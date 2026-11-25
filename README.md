# rog-control-macos

<p align="center"><img src="docs/images/app-icon.png" alt="ROG Control app icon" width="128"></p>

**ROG Control for macOS on the ASUS ROG Zephyrus G14 (GA403WM):** performance modes, power limits, fans, battery charge
limit, GPU mode, lighting and Fn keys from a menu bar app, backed by three kexts.

<p align="center"><img src="docs/images/rogcontrol-window.png" alt="ROG Control 0.6.0 window: live readings, mode, battery, custom limits, lighting, sound, GPU mode and diagnostics" width="860"></p>
<p align="center"><em>ROG Control 0.6.0, the whole window with Diagnostics open. Screenshots are offscreen renders with sample values.</em></p>

<p align="center"><img src="docs/images/rogcontrol-popover.png" alt="ROG Control menu bar panel with the GPU row" width="320"></p>
<p align="center"><em>Menu bar panel</em></p>

macOS has no driver for ASUS's ACPI WMI device, so the embedded controller keeps the profile and power limits it booted
with and nothing on macOS can change them. This repo is the macOS counterpart of Linux `asus-wmi` / `asus-armoury`
(the kext) and of `asusd` / `rog-control-center` from [asusctl](https://github.com/opengamingcollective/asusctl) (the app).
No asusctl code is included; see [Credits](#credits) and [NOTICE.md](NOTICE.md).

> Part of the [GA403WM Hackintosh](https://github.com/thanhnndev/ga403wm-hackintosh) project (OpenCore EFI and index of the
> parts). Sibling repo for the radio chip: [mt7925-macos](https://github.com/thanhnndev/mt7925-macos) (Wi-Fi and Bluetooth).

> [!WARNING]
> **Vibe-coded, kernel code, one laptop.** Almost all of this was written by an AI (Claude) and tested on one GA403WM.
> The kexts run in the kernel. `AsusWmi` writes to the EC and the BIOS (fans, power limits, charge limit).
> `StrixDgpuGate` runs ACPI methods that cut power to the discrete GPU and removes its devices from the PCI bus.
> Read the source before you install anything, and keep a way to boot without the kexts (OpenCore picker, or remove
> the kext from `config.plist`). No warranty.

## Highlights

"Verified" means seen working on the GA403WM, with the date. "Daily use" means it runs every day on macOS 26.7.2 and
nobody recorded a separate test of that feature on Tahoe.

| Feature | State on the GA403WM |
|---|---|
| **Performance modes**: Silent, Balanced, Turbo and Custom, with a different mode on the charger and on battery, switched automatically | Verified 2026-10-12 on macOS 15. Daily use on macOS 26 |
| **Live readings**: CPU temperature, package power, both fan speeds, and the last 4 minutes as a graph | Daily use on macOS 26 (`AmdCppc` 0.2.1 + `AsusWmi`) |
| **Custom power limits** (burst, boost, sustained), range-checked for the charger or the battery | Verified 2026-10-12 on macOS 15. Daily use on macOS 26 |
| **Fan curves** read from the firmware, per mode | Verified 2026-10-12 on macOS 15. `AsusWmi` 0.3.1 fixes the Turbo and Silent curves being swapped: loaded since 2026-11-18, **the read-back on the machine is still owed** |
| **Battery charge limit**: 60, 80 or 100 % | Verified 2026-10-12 on macOS 15. Daily use on macOS 26 |
| **GPU mode: Eco** powers the RTX 5060 off through `StrixDgpuGate` and takes it off the PCI bus | Verified: powers off since 2026-11-09; off the bus and no 60 s login wait since 2026-11-19; every boot in the log since 2026-11-18 came up in Eco, except the ones the loop guard tripped. **Sleep / wake in Eco is not tested.** No HDMI in Eco (the port is wired to the RTX) |
| **GPU mode: Standard / Optimized** | Standard is the state without the gate. Optimized (Eco on battery, decided at boot): no test recorded. Every change needs a restart |
| **Diagnostics**: the gate's state, the loop guard, the power-source heartbeat, the CPU policy | Daily use. The loop guard has tripped on boots that did not hang; 0.2.4 and later fix the known cause |
| **Slash LED** animations, **keyboard backlight** and **Aura** (Static / Breathe / Strobe) | Keyboard light and Slash verified 2026-10-12 on macOS 15; Aura released in 0.5.2, tested on macOS 26.7.1 |
| **Fn / ROG keys** through `rogkeyd` (keyboard light, Aura, mode, brightness, mic mute, airplane mode, M4) | Released in 0.5.2, tested on macOS 26.7.1. Daily use |
| **Doctor**: one list of every dependency, with guided fixes for missing permissions | Released in 0.5.2. Daily use |
| **Sound output** with the ROG speaker profile, **Clear Mic** noise reduction, microphone and camera state | The controls are in the app. The audio parts behind them (`SimpleHDA`, `rogaudiod`, the RogAudio plug-in) are **not in this repository or its releases**; they come from the [GA403WM Hackintosh](https://github.com/thanhnndev/ga403wm-hackintosh) project. Without them the rows show nothing to control |

Not done: sleep / wake and charger-plug tests with the RTX off the bus, a live GPU switch without a restart, any other
ASUS model. The power-limit ranges are the GA403WM's.

## What is in it

| Part | Where | What it does |
|---|---|---|
| `AsusWmi.kext` 0.3.1 | `kexts/AsusWmi` | Matches the ACPI `ATKD` device (`PNP0C14`, `_UID "ATK"`) and calls its WMI methods like `asus-wmi`: platform profile, PPT limits (range-checked for AC or battery), fan curves, fan speeds, charge limit, keyboard light and Aura (N-KEY HID reports), Slash lighting, the Fn keys rogkeyd passes on, GPU state and the stored GPU mode (ABI 6) |
| `StrixDgpuGate.kext` 0.2.12 | `kexts/StrixDgpuGate` | GPU mode. In Eco it claims the RTX before the NVIDIA driver, powers it off through the firmware's own ACPI path and removes it from the PCI bus. Does nothing outside macOS 26 (Darwin 25.x). Details and switches: [docs/GPU-MODE.md](docs/GPU-MODE.md) |
| `AmdCppc.kext` 0.2.1 | `kexts/AmdCppc` | Ryzen AI 9 HX 370: Tctl and package power (`debug.amdcppc.sensors`), per-CPU clocks (`debug.amdcppc.freq`), CPPC boost and EPP controls |
| `RogControl.app` 0.6.0 | `macos/RogControl` | SwiftUI menu bar app plus a window: mode, live readings, battery, Custom limits, lighting, sound, microphone and camera, GPU mode, diagnostics, and a Doctor that checks the whole setup. Talks to AsusWmi through its user client, no sudo. One copy per user |
| `rogkeyd.app` 1.2 | `macos/RogKeys` | LaunchAgent that reads the N-KEY Fn keys (vendor report 0x5A), which macOS drops, and hands them to AsusWmi; does mic mute, airplane mode, Fn+F9 and M4 itself. Needs Input Monitoring (and Accessibility for Fn+F9) |
| `AmdCppcPolicy` | `macos/AmdCppcPolicy` | Root LaunchDaemon that applies the CPPC policy after boot and wake (EPP per profile as asusctl's defaults) |

## Status (2026-11-25)

Reference unit: GA403WM, Ryzen AI 9 HX 370, RTX 5060, macOS 26.7.2 (Darwin 25.6). The versions in the table above are the
ones loaded on that machine. The 2026-10-12 confirmations were made on macOS 15 (24H32); the table in
[Highlights](#highlights) says what has been checked since. Other ASUS models are untested. Per-feature detail and the open
items: [docs/ASUSCTL-MACOS.md](docs/ASUSCTL-MACOS.md); GPU mode: [docs/GPU-MODE.md](docs/GPU-MODE.md).

Known issues:

- Sleep / wake with the RTX off the bus is untested.
- Plugging the charger in hard-hung an Eco boot once (2026-11-10). Not reproduced; cause not proven.
- A restart on 2026-11-23 took 3 min 51 s between "will restart" and the reset. Cause unknown.
- Everything is ad-hoc signed, not notarised.

## Screenshots

<p align="center"><img src="docs/images/rogcontrol-main.png" alt="ROG Control window with Diagnostics closed" width="860"></p>
<p align="center"><em>The compact window: readings and mode on top, battery, Custom limits, lighting, sound and GPU mode below.</em></p>

<p align="center"><img src="docs/images/rogcontrol-gpu-restart.png" alt="GPU mode: Eco requested, restart required" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-gpu-tripped.png" alt="GPU mode: the loop guard tripped and the Mac started in Standard" width="430"></p>
<p align="center"><em>GPU mode: a change takes effect at the next restart; if an Eco start did not finish, the loop guard starts the next one in Standard and says so.</em></p>

<p align="center"><img src="docs/images/rogcontrol-doctor.png" alt="Doctor dialog: drivers, Fn keys, audio, microphone, camera and system checks" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-doctor-fix.png" alt="Doctor guided fix for rogkeyd's Input Monitoring permission" width="430"></p>
<p align="center"><em>Doctor: every dependency in one list, and the guided fix for a missing permission</em></p>

<p align="center"><img src="docs/images/rogcontrol-limits.png" alt="Custom limits dialog" width="430">&nbsp;&nbsp;<img src="docs/images/fan-curves.png" alt="Fan curves dialog" width="430"></p>
<p align="center"><em>Custom limits dialog (burst, short boost, sustained in plain words) and the firmware fan curves</em></p>

<p align="center"><img src="docs/images/rogcontrol-battery.png" alt="Battery dialog" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-lighting.png" alt="Slash animations dialog" width="430"></p>
<p align="center"><em>Battery dialog (charge limit presets, health) and Slash animations with a G14 lid preview</em></p>

<p align="center"><img src="docs/images/rogcontrol-general.png" alt="Settings dialog" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-popover-restart.png" alt="Menu bar panel with a GPU change waiting for a restart" width="240"></p>
<p align="center"><em>Settings, and the menu bar panel with a GPU change waiting for a restart</em></p>

<p align="center"><img src="docs/images/rogcontrol-offline.png" alt="RogControl window without AsusWmi loaded (0.5 design)" width="430">&nbsp;&nbsp;<img src="docs/images/rogcontrol-popover-offline.png" alt="RogControl menu bar panel without AsusWmi loaded (0.5 design)" width="240"></p>
<p align="center"><em>Without AsusWmi loaded the controls are off and nothing is guessed (these two renders are from 0.5).</em></p>

<p align="center"><img src="docs/images/logo-concepts.png" alt="App icon concepts" width="720"></p>
<p align="center"><em>App icon concepts; C (Slash shard) was chosen.</em></p>

## Releases

| Release | Contents |
|---|---|
| `rogcontrol-v0.6.0` | GPU mode. `RogControl-0.6.0.dmg`, `StrixDgpuGate-0.2.12.kext.zip`, `AsusWmi-0.3.1.kext.zip`, `AmdCppc-0.2.1.kext.zip`, `rogkeyd-1.2.app.zip`, `AmdCppcPolicy.zip`: the binaries that run on the test machine. Notes: [.github/release-notes/rogcontrol-v0.6.0.md](.github/release-notes/rogcontrol-v0.6.0.md) |
| [rogcontrol-v0.5.2](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.5.2) | `RogControl-0.5.2.dmg`: Doctor (checks and guided fixes), Aura control, sound row on the grid, one copy per user. `AsusWmi-0.2.2.kext.zip` (Fn keys, Aura, the Fn+F7/F8 panic fix; ABI 5) and `rogkeyd-1.2.app.zip` (Fn keys reader); see [docs/FN-HOTKEYS.md](docs/FN-HOTKEYS.md) |
| [rogcontrol-v0.4.0](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.4.0) | `RogControl-0.4.0.dmg`: sound output, sound profile, microphone, Clear Mic and camera |
| [rogcontrol-v0.3.3](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.3.3) | `RogControl-0.3.3.dmg`: one-screen window with dialogs, no spare space, menu bar icon in the app badge style, steadier temperature and power readings; open it and drag the app into Applications. Kexts unchanged, still in `rog-v1.0` |
| [rog-v1.0](https://github.com/thanhnndev/rog-control-macos/releases/tag/rog-v1.0) | `AsusWmi.kext`, `AmdCppc.kext`, `AmdCppcPolicy`, `RogControl.app`, `SHA256SUMS.txt`. Binaries copied unchanged from `kext-v1.1` of the EFI repo; same checksums |

## Build

On macOS with the Xcode command line tools (the kexts cannot be built on Linux):

```bash
bash scripts/build.sh                      # build/AsusWmi.kext, build/AmdCppc.kext, build/StrixDgpuGate.kext
bash scripts/build-amdcppc-policy.sh       # build/AmdCppcPolicy
bash scripts/test-rogcontrol.sh            # fan-curve decoding, never writes hardware
bash scripts/build-rogcontrol.sh           # build/RogControl.app
bash scripts/build-rogcontrol.sh --install # copy to /Applications, start at login
bash scripts/build-rogkeys.sh --install    # rogkeyd LaunchAgent (Fn keys); then grant Input Monitoring
bash scripts/build-dmg.sh                  # build/RogControl-<version>.dmg, drag-to-Applications installer
```

CI builds the same on `macos-15` and uploads the zips as a workflow artifact (ad-hoc signed; nothing is notarized). CI does
not package `StrixDgpuGate` yet, and `rogcontrol-v*` releases are attached by hand.

## Install the kexts

OpenCore loads what `config.plist` lists, by path. Copy the kext into `EFI/OC/Kexts`, add it under `Kernel > Add`, reboot.
`scripts/macos-install-kext.sh AsusWmi` does the copy and keeps the old kext in `EFI/OC/Kexts-backup`; `--undo` puts it
back. It does not edit `config.plist`. AmdCppc and its policy daemon: [docs/CPU-POWER.md](docs/CPU-POWER.md).
`StrixDgpuGate`: read [docs/GPU-MODE.md](docs/GPU-MODE.md) first; it lists the order in `Kernel > Add`, the off switches
(`-strixgate_off`, NVRAM `strix-gpu-keepbus=1`) and what to watch on the first boot.

## Docs

* [docs/ASUSCTL-MACOS.md](docs/ASUSCTL-MACOS.md): feature map, WMI device ids, ABI, measurements.
* [docs/rog-control-design.md](docs/rog-control-design.md): menu bar and window design decisions, fan-curve drawing rules.
* [docs/CPU-POWER.md](docs/CPU-POWER.md): AmdCppc audit and the CPPC policy.
* [docs/GPU-MODE.md](docs/GPU-MODE.md): GPU mode, StrixDgpuGate, the loop guard and its switches.
* [docs/FN-HOTKEYS.md](docs/FN-HOTKEYS.md): the Fn key map, rogkeyd, and why the keyboard driver is not replaced.
* [docs/AUDIO-ROG.md](docs/AUDIO-ROG.md) (branch `dev/audio`).

## Branches

* `main`: release 0.6.0 (app, rogkeyd, AsusWmi 0.3.1, AmdCppc, StrixDgpuGate 0.2.12): the merge of `fix/eco-offbus` and
  `fix/fan-curve-index`, which also carries pull requests 16 and 17. StrixDgpuGate 0.2.13 (never loaded) stays on `fix/eco-offbus`.
* `dev/fn-hotkeys`: an earlier Fn key attempt through ATKD WMI, which never fires on this machine. Superseded by rogkeyd; not merged.
* `dev/audio`: a from-scratch rewrite of the app with an audio page, the RogAudio HAL plug-in and mic chain. Speakers were
  still silent in audible tests when the branch was last touched. Not merged.

The history of these files was split out of `thanhnndev/ga403wm-hackintosh` with `git filter-repo`; commits keep their
original dates and authors.

## Related repositories

All of these belong to one project: macOS on one ASUS ROG Zephyrus G14 **GA403WM**.

| Repository | What it is | Latest release |
|---|---|---|
| [ga403wm-hackintosh](https://github.com/thanhnndev/ga403wm-hackintosh) | The hub: OpenCore EFI, ACPI, install notes, state and roadmap, the small helper kexts | [v2 (macOS 26 Tahoe)](https://github.com/thanhnndev/ga403wm-hackintosh/releases/tag/v2) |
| [mt7925-macos](https://github.com/thanhnndev/mt7925-macos) | MediaTek MT7925 Wi-Fi (`itlmt7925`, `itlmt7925Native`) and Bluetooth (`MtkBtFw`, `BtLeDlFix`) | Wi-Fi [v2.0-beta.1](https://github.com/thanhnndev/mt7925-macos/releases/tag/v2.0-beta.1), Bluetooth [bt-v1.1](https://github.com/thanhnndev/mt7925-macos/releases/tag/bt-v1.1) |
| [rog-control-macos](https://github.com/thanhnndev/rog-control-macos) | RogControl app, `AsusWmi`, `AmdCppc`, `rogkeyd`, `StrixDgpuGate` (performance modes, fans, charge limit, GPU mode, Slash, Fn keys) | [rogcontrol-v0.6.0](https://github.com/thanhnndev/rog-control-macos/releases/tag/rogcontrol-v0.6.0) |
| [nvidia-macos-driver](https://github.com/thanhnndev/nvidia-macos-driver) (fork of [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver)) | The Radeon 890M display and Metal driver for this laptop (`NMXGPU` and its Metal plugin), PolyForm Noncommercial | source tags [ga403wm-890m-out50](https://github.com/thanhnndev/nvidia-macos-driver/releases/tag/ga403wm-890m-out50), [ga403wm-890m-plugin-a6cec1b](https://github.com/thanhnndev/nvidia-macos-driver/releases/tag/ga403wm-890m-plugin-a6cec1b) |
| [ryzen-hypervisor.framework](https://github.com/thanhnndev/ryzen-hypervisor.framework) (fork of [OverlordDev/ryzen-hypervisor.framework](https://github.com/OverlordDev/ryzen-hypervisor.framework)) | AMD-V hypervisor for Docker and the Android emulator on Ryzen, with this machine's fixes | source tag [v0.7.24-ga403wm](https://github.com/thanhnndev/ryzen-hypervisor.framework/releases/tag/v0.7.24-ga403wm) |
| [strix-890m-macos](https://github.com/thanhnndev/strix-890m-macos) | Earlier Radeon 890M research: notes, boot-display kexts, traces. Superseded by the driver above | none |

## Credits

Nothing in this repository is copied from the projects below. They are what made it possible.

| Project | What it gave this one |
|---|---|
| [asusctl / rog-control-center](https://github.com/opengamingcollective/asusctl) and [asus-linux.org](https://asus-linux.org), by Luke Jones and the asus-linux contributors (MPL-2.0) | The feature set and how it is organised: platform profile, PPT power limits, charge limit, per-board limits, the EPP defaults per profile |
| Linux `asus-wmi` (Corentin Chary and contributors, GPL-2.0-or-later) and `asus-armoury` (Luke Jones, GPL-2.0) | The WMI method and device ids, the DSTS / DEVS convention, profile values and the GA403WM power-limit ranges. Interface values only |
| Linux `k10temp` / `amd_nb` (GPL-2.0) | The SMN address of Tctl and the host-bridge index / data registers used by `AmdCppc`. Interface values only |
| [G-Helper](https://github.com/seerge/g-helper) | The HID report sequences for the keyboard light and the Slash display, the mode names, and a UX reference |
| [asusctltray](https://github.com/Baldomo/asusctltray) | A UX reference |
| [acidanthera/MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) | Kernel headers and libraries at build time; not redistributed |
| [OpenCore](https://github.com/acidanthera/OpenCorePkg) (acidanthera) | The boot loader that injects the kexts |
| [NullMoth Systems' NVIDIA driver for macOS](https://github.com/nullmoth/nvidia-macos-driver) | The RTX driver that `StrixDgpuGate` steps in front of in Eco; not part of this repository |
| [Claude](https://claude.com/claude-code) (Anthropic) | Wrote most of the code and documentation, directed and tested by thanhnndev |

Licences, file by file: [NOTICE.md](NOTICE.md).

## License

[Clear BSD](LICENSE). Third-party notes: [NOTICE.md](NOTICE.md).

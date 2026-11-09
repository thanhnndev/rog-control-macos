// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// User client ABI of AsusWmi (IOServiceOpen on the "AsusWmi" service, type 0). Used by macos/RogControl.
// Allowed for root, an administrator, or the user logged in at the console (as the itlmt7925 user client).
#ifndef ASUSWMI_ABI_H
#define ASUSWMI_ABI_H

#define ASUSWMI_ABI_VERSION 6

enum {
    kAsusUcGetState  = 0,   // out: struct, uint32_t[ASUS_ST_COUNT]
    kAsusUcSet       = 1,   // in: scalars { what (ASUS_SET_*), value }
    kAsusUcFanRead   = 2,   // in: scalars { fan (0 cpu, 1 gpu), profile (0 balanced, 1 turbo, 2 silent) }; out: struct 16 bytes
                            //     (8 temperatures in °C, then 8 fan duties in %): the firmware's curve for that profile
    kAsusUcFanWrite  = 3,   // in: scalars { fan }, struct 16 bytes (same layout): custom curve, makes the fans "manual"
    kAsusUcFanReset  = 4,   // re-applies the current profile: firmware fan curves, power limits back to the profile's
    kAsusUcKey       = 5,   // in: scalars { code }: an Fn key code from the N-KEY keyboard (HID report 0x5A), read by rogkeyd
                            //     (ABI 4); handled as a hotkey, see AsusWmi.cpp
    kAsusUcGpuGet    = 6,   // out: struct, uint32_t[ASUS_GP_COUNT]: GPU mode state (ABI 6), see docs/GPU-MODE.md
    kAsusUcGpuSet    = 7,   // in: scalars { what (ASUS_GPU_SET_*), value } (ABI 6)
};

// ---- GPU mode (ABI 6) -------------------------------------------------------------------------------------------------------
// Eco = the RTX is kept away from NVRM at boot and powered off (StrixDgpuGate); there is no live switch, the stored mode
// takes effect at the next boot. The mode lives in the NVRAM variable ASUS_GPU_NVRAM_VAR, written by this kext.
#define ASUS_GPU_NVRAM_VAR "strix-gpu-mode"           // "standard" | "eco" | "optimized"; absent = standard
enum {                      // the stored mode / the mode the gate resolved for this boot
    ASUS_GPU_STANDARD  = 0, // hybrid: NVRM drives the RTX
    ASUS_GPU_ECO       = 1, // dGPU off
    ASUS_GPU_OPTIMIZED = 2, // Eco when the boot starts on battery, Standard on AC (decided once, at boot)
    ASUS_GPU_ULTIMATE  = 3, // MUX to the dGPU: never selectable (the 890M stack would lose the panel); reported only
};
enum {                      // kAsusUcGpuSet "what"
    ASUS_GPU_SET_MODE  = 1, // value 0..2: store the mode for the next boot (NVRAM). Always allowed.
    ASUS_GPU_SET_DGPU  = 2, // value 0/1: WMI DEVS 0x00090020 (ACPI hot eject + EC rail). Only with the RTX provably detached from NVRM
                            //     and the gate active; expert/test use, the app does not call it (see docs/GPU-MODE.md)
    ASUS_GPU_SET_MUX   = 3, // value 0/1: WMI DEVS 0x00090016. Refused unless boot-arg asuswmi_mux=1 (it moves the panel to the RTX)
};
enum {                      // kAsusUcGpuGet words
    ASUS_GP_ABI = 0,        // ASUSWMI_ABI_VERSION
    ASUS_GP_FLAGS,          // ASUS_GPF_*
    ASUS_GP_MODE,           // stored mode (ASUS_GPU_*), 0xFFFFFFFF = variable absent (Standard)
    ASUS_GP_BOOT,           // what the gate resolved at this boot: ASUS_GPU_STANDARD / ASUS_GPU_ECO, 0xFFFFFFFF = gate not loaded
    ASUS_GP_DGPU_DSTS,      // raw DSTS 0x00090020
    ASUS_GP_MUX_DSTS,       // raw DSTS 0x00090016
    ASUS_GP_PG00_STA,       // \_SB.PCI0.GPP9.PG00._STA as the gate saw it (1 on, 0 off), 0xFFFFFFFF unknown
    ASUS_GP_DARWIN,         // Darwin major (25 = macOS 26)
    ASUS_GP_COUNT = 8
};
#define ASUS_GPF_SUPPORTED   0x01u   // Darwin 25.x and the firmware reports the dGPU-disable device
#define ASUS_GPF_GATE        0x02u   // StrixDgpuGate is loaded
#define ASUS_GPF_GATE_HELD   0x04u   // the gate holds the RTX this boot (NVRM not attached)
#define ASUS_GPF_POWERED_OFF 0x08u   // the gate powered the RTX off (PG00._OFF ran and PG00._STA reads 0)
#define ASUS_GPF_NVRM        0x10u   // a driver other than the gate is attached to the RTX
#define ASUS_GPF_NVRAM_OK    0x20u   // the mode variable can be written
#define ASUS_GPF_TRIPPED     0x40u   // the gate refused to claim because the previous Eco boot did not finish (loop guard)
#define ASUS_GPF_MUX_UNLOCK  0x80u   // boot-arg asuswmi_mux=1
#define ASUS_GPF_LIVE_OK     0x100u  // the RTX is provably detached from NVRM: ASUS_GPU_SET_DGPU is allowed

enum {                      // kAsusUcSet "what"
    ASUS_SET_PROFILE = 1,   // 0 balanced (Armoury Crate "Performance"), 1 turbo, 2 silent
    ASUS_SET_SPL     = 2,   // W, PL1 sustained; needs a custom fan curve first (asus-armoury: requires_fan_curve on GA403WM)
    ASUS_SET_SPPT    = 3,   // W, PL2 slow
    ASUS_SET_FPPT    = 4,   // W, PL3 fast
    ASUS_SET_CHARGE  = 5,   // %, battery charge end 20..100
    ASUS_SET_BACKLIGHT = 6, // EC brightness level 0..ASUS_ST_BACKLIGHT_MAX (AWMI.WMAA); not the OLED's: that is NullMoth's AUX path
    ASUS_SET_KBD     = 7,   // keyboard backlight 0..3 (N-KEY HID feature report 0x5A)
    ASUS_SET_AURA    = 9,   // keyboard Aura mode: 0 static, 1 breathe, 2 strobe (N-KEY report 0x5D; single-color keyboard) (ABI 5)
    ASUS_SET_SLASH   = 8,   // Slash lighting: ASUS_SLASH_PACK(mode, brightness, interval); brightness 0 = off
};

enum {                      // kAsusUcGetState words
    ASUS_ST_ABI = 0,
    ASUS_ST_FLAGS,          // ASUS_FL_*
    ASUS_ST_PROFILE,        // 0..2 as last set since boot (the BIOS's DSTS does not report it), 0xFFFFFFFF unknown
    ASUS_ST_CHARGE,         // %, as last set since boot (DSTS reads 0 on this BIOS), 0xFFFFFFFF unknown
    ASUS_ST_CPU_FAN_RPM,
    ASUS_ST_GPU_FAN_RPM,
    ASUS_ST_SPL,            // W last set through AsusWmi since boot / the last profile change; 0 = the profile's own
    ASUS_ST_SPPT,
    ASUS_ST_FPPT,
    ASUS_ST_SPL_MIN, ASUS_ST_SPL_MAX,     // ranges for the current power source (asus-armoury, GA403WM)
    ASUS_ST_SPPT_MIN, ASUS_ST_SPPT_MAX,
    ASUS_ST_FPPT_MIN, ASUS_ST_FPPT_MAX,
    ASUS_ST_GPU_MUX,        // raw DSTS
    ASUS_ST_DGPU_DISABLE,   // raw DSTS
    ASUS_ST_NV_BASE_TGP,    // W
    ASUS_ST_BACKLIGHT,      // current level, 0xFFFFFFFF unknown
    ASUS_ST_BACKLIGHT_MAX,  // 0 = no EC backlight control
    ASUS_ST_BAT_DESIGN,     // mAh, design capacity (_BIF); 0 unknown
    ASUS_ST_BAT_FULL,       // mAh, last full charge capacity
    ASUS_ST_BAT_NOW,        // mAh, remaining
    ASUS_ST_BAT_STATE,      // bits 0-7: _BST state (1 discharging, 2 charging), bits 8-31: rate in mA
    ASUS_ST_KBD,            // keyboard backlight 0..3 as last set (the keyboard cannot be read), 0xFFFFFFFF unknown
    ASUS_ST_SLASH,          // Slash setting as last set (ASUS_SLASH_PACK), 0xFFFFFFFF unknown
    ASUS_ST_HID,            // 1: the N-KEY keyboard (0b05:19b6) was found
    ASUS_ST_AURA,           // Aura mode 0..2 as last set (ABI 5), 0xFFFFFFFF unknown
    ASUS_ST_COUNT = 28,
    ASUS_ST_COUNT_V3 = 27   // what ABI 3 / 4 clients ask for: they still get those words
};

#define ASUS_FL_AC         0x1u    // on AC power (ACPI0003 _PSR)
#define ASUS_FL_FAN_CUSTOM 0x2u    // a custom fan curve is active (written since the last profile change)

// Slash: mode index (ASUS_SLASH_MODES order, as G-Helper's SlashMode), brightness 0..3, interval 0..5 (animation speed)
#define ASUS_SLASH_PACK(mode, bright, interval) ((uint32_t)(mode) | ((uint32_t)(bright) << 8) | ((uint32_t)(interval) << 12))
#define ASUS_SLASH_MODE(v)     ((v) & 0xff)
#define ASUS_SLASH_BRIGHT(v)   (((v) >> 8) & 0xf)
#define ASUS_SLASH_INTERVAL(v) (((v) >> 12) & 0xf)
#define ASUS_SLASH_MODES "Static", "Bounce", "Slash", "Loading", "Bit Stream", "Transmission", "Flow", "Flux", \
                         "Phantom", "Spectrum", "Hazard", "Interfacing", "Ramp", "Game Over", "Start", "Buzzer"
#define ASUS_SLASH_MODE_COUNT 16

#endif

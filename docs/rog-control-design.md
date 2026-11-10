# ROG Control interaction design

ROG Control is primarily a menu bar hardware utility. Daily adjustments should be completed in its panel; the standalone window supports longer inspection and adjustment.

## Research and decisions

- [Apple Control Center](https://support.apple.com/en-ca/guide/mac-pro/apdc362a41b2/mac): immediate access to frequently used controls.
- [Apple popovers](https://developer.apple.com/design/human-interface-guidelines/popovers): limit related tasks, avoid oversized panels, and keep multiple selections possible until dismissal.
- [NN/G progressive disclosure](https://www.nngroup.com/articles/progressive-disclosure/): keep frequent actions visible, reveal secondary information on demand.
- [NN/G system status](https://www.nngroup.com/articles/visibility-system-status/): communicate actual state and action failures.
- [G-Helper](https://github.com/seerge/g-helper) and [asusctltray](https://github.com/Baldomo/asusctltray): direct profile selection and hardware controls from a resident utility.

Taste v2 targets web landing pages and redesigns. It is not the foundation for this native utility. The confirmed user requirement is frequent interaction through the menu bar. Per-feature usage frequency has not been measured.

## Visual language

The panel and the window share one dark ROG look: one red accent (amber only for warnings), chamfered cards with the top-right corner cut, and the lid's Slash LED segments as slanted bars for fan speed, mode level and battery charge. Numbers use the expanded system width; labels are small tracked capitals. Both surfaces are always dark. The app icon ("Slash shard": a chamfered plate cut by three Slash segments) is a layered Icon Composer file in `macos/RogControl/icon`, compiled by `actool` into Assets.car (Liquid Glass, dark and tinted on Tahoe) and AppIcon.icns for macOS 13 to 15. No ASUS or ROG marks are used.

Colour rules (WCAG AA, ratios from the relative-luminance formula on the values in `enum T`): small labels use `T.faint` (0.52, 0.54, 0.57), at least 4.7:1 on every surface. White text sits on `T.redFill` (0.86, 0.10, 0.20, 5.0:1), never on `T.red` (3.8:1); `T.red` is for strokes, segments, the gauge arc and red text on dark (5.2:1). Red means selected or active, so failures beside a control (`ErrorLine`) are amber with the warning triangle and say "was not applied". Without AsusWmi nothing hardware-derived is shown or selected: no charge limit, keyboard or Slash selection, no power source, no battery state, no chart history; only saved preferences (custom limits) stay visible.

## Primary panel

Only what is used daily: CPU temperature (the one large number) with package power and fan speeds, the four modes as a 2x2 grid (Silent, Balanced, Turbo, Custom), the charge limit and the keyboard light. Turbo is disabled on battery with "Needs charger". Custom shows "Set up…" until limits are saved and then opens the window with the Custom limits dialog. After an automatic switch on plug or unplug, one line says what changed. Power limits are not in the panel.

## Window

One screen, no side menu (like NitroSense). The top row is the live card (CPU and package gauges, fan bars, power limit, GPU mode, TGP and a temperature and power chart) and the mode card (four mode rows plus the mode used on the charger and on battery). The bottom row has three tiles with their everyday control inline: Battery (level and charge limit), Custom limits (burst, short boost, sustained bars and the fan curve they follow) and Lighting (Slash on/off and brightness, keyboard brightness).

Anything set up once opens as a dialog over the dimmed screen: Custom limits (sliders in plain words with FPPT/SPPT/SPL codes as small labels, a picture of how the CPU uses them, Reset and Save to Custom), Fan curves (firmware CPU and GPU curves), Slash animations, Battery (presets, health, current) and Settings (open at login, about). The close button, Esc and a click on the dim area close a dialog. Without AsusWmi the header chip says so and the controls are off.

The Slash dialog shows a drawn G14 lid with the seven Slash zones playing an approximation of the chosen mode (brightness and pause applied); hovering a mode previews it before it is applied. Opening the menu bar panel activates the app, which would raise a ROG window left behind other apps, so that window is taken off screen while the panel is open and put back behind the other apps afterwards.

The header sits in the title bar next to the traffic lights and the window is exactly as tall as its content: no empty bands. The menu bar icon is the same chamfered mode badge as in the app, drawn as a template with the glyph cut out.

Temperature and package power are smoothed (exponential average) and shown as whole degrees and watts that only move when the smoothed value is 1 °C or 2 W away. Live readings swap in place without the rolling-digit animation; only the gauge arc glides.

Motion is brief: numbers roll on macOS 14+, gauges and segments ease, mode selection animates; Reduce Motion turns the panel's motion off. Nothing spins.

## Fan curves

The AsusWmi ABI returns 16 bytes: eight temperatures followed by eight fan duties. Read-only inspection of this GA403WM returned a 255°C endpoint in both Turbo curves and repeated 70°C points in the Turbo GPU curve. The former drawing code projected 255 outside its 20–105°C chart with no clipping or axes.

Swift Charts now uses explicit 20–105°C and 0–100% axes, linear segments, visible points, and CPU/GPU selection. A hover shows a point's temperature/duty. A firmware profile label identifies the source; this is a firmware reference curve, not live RPM or a time series.

Invalid endpoints are omitted with a visible notice, not clamped or assigned a made-up temperature. Interior invalid samples break the line. Repeated valid temperatures are preserved. Malformed or unavailable data produces an explicit empty state. The selected manual fan base can be previewed independently of Apply. Driver curve validation and hardware behavior remain unchanged.

## App behavior

Build with `bash scripts/build-rogcontrol.sh`; install and relaunch with `bash scripts/build-rogcontrol.sh --install`. A regular launch opens the app window; `--background` runs in the menu bar. Closing the window keeps the utility running. AC/battery preferences remain independent.

The window has Performance, Battery, Lighting and General. Command-0 opens it; Command-R refreshes; Command-W closes; Command-M minimizes; Command-Q quits. Geometry is saved.

## Verification

`bash scripts/test-rogcontrol.sh` tests decoding using real firmware samples: Turbo 255 endpoints, duplicate temperatures, gaps, invalid duty, descending points, short buffers, and empty data. It never writes hardware.

Offscreen native AppKit/SwiftUI renders were inspected for the light/dark primary panel, Manual sliders, the Performance chart, and the Turbo omission notice. Default controls fit without scrolling; selected keyboard and charge levels remain visible. Build target remains macOS 13, x86_64.

These checks validate layout and decoding. They do not replace observed user-task testing, and hardware-setting actions were not exercised as part of the chart tests.

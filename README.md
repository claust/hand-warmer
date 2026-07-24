# Hand Warmer 🔥

An iOS app that turns your iPhone into a pocket hand warmer. Cold fingers at the
bus stop? Open the app, press the big button, and let the phone's own silicon do
the rest.

## How it works

Pressing **WARM ME** lights an animated flame and deliberately makes the device
as busy as possible:

- **CPU** — one busy-loop math thread per core (always on while warming), the
  most effective way to generate heat.
- **GPS booster** — navigation-grade location updates keep the GPS chip busy.
- **Bluetooth booster** — continuous scanning with duplicates allowed keeps the
  radio hot.
- **Torch booster** — full-power flashlight, which genuinely warms the camera
  area.

The screen stays awake as long as the app is visible, so the warmth doesn't
stop when you stop tapping.

## Telemetry & safety

- **Heat level** — iOS has no public API for the actual temperature in degrees,
  so the app shows `ProcessInfo.thermalState` as a live badge instead:
  Cool → Warm → Hot → Very hot. Watching it climb is your proof it's working.
- **Low battery warning** — below 20% (and not charging), starting the warmer
  asks for confirmation, since it drains power fast enough to shut the phone
  down.
- **Critical shutdown** — if iOS reports a critical thermal state, the warmer
  switches itself off and asks you to let the phone cool down.
- The engine also stops when the app is backgrounded — no hidden battery drain.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open HandWarmer.xcodeproj
```

Select your development team under *Signing & Capabilities* and run. The UI
works in the simulator, but actual heating (and battery/thermal readouts)
requires a real device — the simulator borrows your Mac's CPU and reports no
battery.

If you are not the owner of this repo, change `bundleIdPrefix` in
`project.yml` to something under your own team before running `xcodegen
generate`. Automatic signing has to register the App ID under your team, and
`com.claus.HandWarmer` already belongs to someone else's.

Launch with the `-autostart` argument to start the warmer automatically
(used for automated UI verification).

## Requirements

- iOS 17.0+
- Xcode 15+ / XcodeGen

⚠️ This app intentionally drains the battery and warms the device. That is the
point. Use in moderation.

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

- **Heat vs. battery** — two horizontal bars at the top show the trade you are
  making: heat fills up while the battery drains down.
- **Heat level** — iOS has no public API for the actual temperature in degrees,
  so the app derives the bar from `ProcessInfo.thermalState`: Cool → Warm →
  Hot → Very hot. Each state owns a band of the bar (marked with ticks), and
  the bar creeps through the current band while warming, so it keeps moving
  between the state changes without ever contradicting the label.
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

Or use the Makefile, which wraps the whole build/deploy/verify loop:

```bash
make ios-run                      # build + launch on the Simulator
make ios-deploy                   # build, sign, install + launch on a connected iPhone
make ios-screenshot TARGET=device # capture the device screen (needs pymobiledevice3)
```

`ios-deploy` auto-detects the connected device (override with
`IOS_DEVICE=<name-or-udid>`) and signs with `IOS_TEAM`, which defaults to this
repo's team — override it with your own. Device screenshots need
`uv tool install pymobiledevice3`; the device must be unlocked.

Select your development team under *Signing & Capabilities* and run. The UI
works in the simulator, but actual heating (and battery/thermal readouts)
requires a real device — the simulator borrows your Mac's CPU and reports no
battery.

If you are not the owner of this repo, change `bundleIdPrefix` in
`project.yml` to something under your own team before running `xcodegen
generate`. Automatic signing has to register the App ID under your team, and
`com.claus.HandWarmer` already belongs to someone else.

Launch with the `-autostart` argument to start the warmer automatically
(used for automated UI verification).

## Tests & lint

```bash
make ios-test   # build + run the unit tests on the Simulator
make check-ios  # SwiftLint + swift-format lint (no changes)
make format-ios # apply swift-format in place
```

Unit tests live in `HandWarmerTests` and run against the simulator (no signing,
no device). Style is split in two: [SwiftLint](https://github.com/realm/SwiftLint)
(`.swiftlint.yml`) owns naming and complexity rules, and swift-format — bundled
with Xcode, configured by `.swift-format` — owns layout. Both run with
`--strict`, so a warning fails the check.

`brew install xcodegen swiftlint xcbeautify` gets the tooling; xcbeautify is
optional and only prettifies the build output.

## CI

[`.github/workflows/ios-ci.yml`](.github/workflows/ios-ci.yml) runs on every
push and pull request against `master`: it regenerates the project with
XcodeGen, lints, builds for testing, and runs the tests on an iPhone 17 Pro
simulator under Xcode 26. Everything is simulator-only and unsigned, so the
workflow needs no secrets. The `.xcresult` bundle is uploaded as an artifact for
7 days when a run fails.

## Requirements

- iOS 17.0+
- Xcode 15+ / XcodeGen

⚠️ This app intentionally drains the battery and warms the device. That is the
point. Use in moderation.

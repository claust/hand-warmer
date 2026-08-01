# Hand Warmer 🔥

An iOS app that turns your iPhone into a pocket hand warmer. Cold fingers at the
bus stop? Open the app, press the big button, and let the phone's own silicon do
the rest.

## How it works

Pressing **WARM ME** lights an animated flame and deliberately makes the device
as busy as possible:

- **CPU** — one busy-loop math thread per core (always on while warming), the
  most effective way to generate heat.
- **GPU booster** — a Metal compute kernel of four-wide fused multiply-adds,
  dispatched back to back. After the CPU cores this is the biggest power draw
  in the chip.
- **Neural booster** — the Apple Neural Engine, kept busy by running a bundled
  Core ML model in a loop. Honest caveat: the ANE is built for inference *per
  watt*, so it is much the weakest of the three silicon boosters.
- **GPS booster** — navigation-grade location updates keep the GPS chip busy.
- **Bluetooth booster** — continuous scanning with duplicates allowed keeps the
  radio hot.
- **Torch booster** — full-power flashlight, which genuinely warms the camera
  area.

The boosters live behind the **Boosters** button at the bottom of the screen,
which opens a translucent panel over the flame. They used to sit on the main
screen, but six chips pushed the title off the top of a shorter phone.

### Feeding the silicon

The two chip boosters are less obvious than "spin a thread", so:

- **The GPU tunes itself.** How much work fits in one dispatch differs by an
  order of magnitude between devices, so the loop measures the *GPU* time of
  each command buffer — not the wall clock around it, which on a phone with six
  cores already busy-looping is mostly scheduler latency — and steers the
  kernel's inner-loop count towards a target. Two buffers stay in flight so the
  GPU never idles waiting for the next submission.
- **iOS sets the ceiling.** Dispatch too greedily and the system aborts the
  buffer with `kIOGPUCommandBufferCallbackErrorImpactingInteractivity`. That is
  treated as information rather than failure: the booster halves its dispatch
  size, remembers that as a ceiling, and carries on underneath it. On an
  iPhone 15 it aims high, gets told off once about four seconds in, and then
  runs indefinitely just below the limit.
- **The ANE needs a model.** There is no API for putting arbitrary work on the
  Neural Engine — it runs compiled network graphs and nothing else. So the app
  ships `HeatNet.mlpackage`, a stack of fp16 convolutions that computes nothing
  and exists only to be expensive (~22 GFLOP per prediction from 1.3 MB of
  weights). Regenerate it with `scripts/make_heatnet.py`; it is committed
  because generating it needs coremltools, which does not ship with macOS.

Both fail quietly if the hardware or the model is missing — a booster that
cannot run should cost no heat, not take the session down. They log what they
are doing, which is how you tell "working" from "silently doing nothing":

```bash
pymobiledevice3 syslog live -pn HandWarmer -mi booster
```

The screen stays awake as long as the app is visible, so the warmth doesn't
stop when you stop tapping.

## In your pocket

Putting the phone away no longer stops the warmer. The session moves to a Live
Activity — an animated flame and a running clock in the Dynamic Island, plus a
banner with the heat bar on the Lock Screen — the same way a timer behaves.

Two things make that work, and both are worth knowing about:

- **Background execution.** A Live Activity grants visibility, not runtime: iOS
  suspends an ordinary app within seconds of backgrounding, and a suspended
  busy loop warms nothing. The app therefore holds an audio session playing a
  generated buffer of silence (`BackgroundKeepAlive`), under the `audio`
  background mode. It is inaudible and mixes with whatever you are listening
  to. It is also the kind of thing App Review asks about, so this is not a
  technique to copy into a shipping app without thought.
- **The flame's frame rate.** The Dynamic Island has no animation clock of its
  own — it redraws only when the app pushes a new activity state, and SF Symbol
  effects do not run there either. So the flame is animated by pushing a new
  wobble phase about twice a second and letting SwiftUI tween the shapes in
  between. That is a lot of traffic for ActivityKit, hence
  `NSSupportsLiveActivitiesFrequentUpdates` in the Info.plist. The elapsed
  clock, by contrast, is a `Text(timerInterval:)` that the system runs itself.

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
- The warmer keeps running when the app is backgrounded, so the drain is no
  longer hidden — that is exactly why the Dynamic Island shows the flame and the
  elapsed time the whole time it is on.

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

## TestFlight

`make ios-deploy` is for the edit-build-look loop, not for keeping the app on a
phone: it signs with a *development* provisioning profile, and when that profile
expires iOS stops launching the app ("Hand Warmer is no longer available"). A
TestFlight build is signed for distribution, lasts 90 days, and is replaced by
uploading again — so this is the way to actually carry the app around.

```bash
make testflight           # archive → export → validate → upload
make testflight-validate  # same, minus the upload (checks signing + App Review's automated checks)
make ios-archive          # just produce build-archive/HandWarmer.ipa
```

The build number is the git commit count, so it climbs on its own — App Store
Connect refuses a `CFBundleVersion` it has already seen. Override with
`BUILD_NUMBER=<n>` when uploading from a branch whose count has drifted below
what is already up there. `MARKETING_VERSION` in `project.yml` stays hand-owned.

### One-time setup

1. **Create an App Store Connect API key.** *Users and Access → Integrations →
   App Store Connect API → Team Keys*, role **App Manager**. Note the Key ID and
   the Issuer ID, and download the `AuthKey_<KEYID>.p8` — Apple serves it once.
2. **Put the key where the tools look:**
   ```bash
   mkdir -p ~/.private_keys && mv ~/Downloads/AuthKey_*.p8 ~/.private_keys/
   ```
3. **Name it in `.testflight.env`** (gitignored; copy `.testflight.env.example`):
   ```
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```
4. **Create the app record** in App Store Connect: *Apps → + → New App*,
   platform iOS, bundle ID `com.claus.HandWarmer`, any SKU. The record cannot be
   created from the command line, and the upload fails without it. Only the
   bundle IDs — app and widget extension — are registered automatically, by
   `xcodebuild -allowProvisioningUpdates`.
5. **Add yourself as an internal tester** under *TestFlight → Internal Testing*,
   then install [TestFlight](https://apps.apple.com/app/testflight/id899247664)
   on the phone. Internal builds skip Beta App Review and appear within minutes
   of processing.

Keep it to internal testing. Two things in this app — the silent audio session
held purely to stay alive in the background, and the premise of deliberately
overheating the device — are the kind of thing Beta App Review asks about for
external testers, and would very likely be rejected for the App Store proper.

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

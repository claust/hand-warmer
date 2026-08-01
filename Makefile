# Makefile for building, deploying and screenshotting Hand Warmer.
# Ported from the pussel repo's iOS targets.
#
# Config knobs — override on the command line, e.g.
#   make ios-run IOS_SIMULATOR="iPhone 17 Pro Max"
#   make ios-deploy IOS_DEVICE=<name-or-udid>

.PHONY: ios-generate ios-build ios-test ios-run ios-deploy ios-screenshot \
	testflight testflight-validate ios-archive \
	format-ios lint-ios check-ios clean

IOS_SCHEME     = HandWarmer
# Built product name (<IOS_APP_NAME>.app). Keep it in sync with IOS_SCHEME's
# target PRODUCT_NAME if you override the scheme.
IOS_APP_NAME   = HandWarmer
IOS_BUNDLE_ID  = com.claus.HandWarmer
IOS_PROJECT    = HandWarmer.xcodeproj
IOS_SIMULATOR ?= iPhone 17 Pro
# Simulator destination shared by ios-build and ios-test (and by CI, which
# overrides it to pin the runtime).
IOS_DESTINATION ?= platform=iOS Simulator,name=$(IOS_SIMULATOR)
IOS_DERIVED    = build
IOS_DERIVED_DEVICE = build-device

# Apple Developer team used for device signing. Automatic signing cannot pick a
# team on its own from the command line, so it must be named here; override with
# `make ios-deploy IOS_TEAM=XXXXXXXXXX` if you build under a different account.
IOS_TEAM ?= RS2FKJW2W4

# Prettifier for xcodebuild output. Optional: `brew install xcbeautify` to get
# readable logs; without it the raw xcodebuild output passes straight through.
BEAUTIFY := $(shell command -v xcbeautify >/dev/null 2>&1 && echo xcbeautify || echo cat)

# Regenerate the (gitignored) Xcode project from project.yml.
# Requires `brew install xcodegen`.
ios-generate:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	xcodegen generate

# Compile the app and its tests for the simulator without running anything.
# No signing is involved, so this needs no developer account. Piped through
# xcbeautify when it is installed, raw otherwise.
ios-build: ios-generate
	set -o pipefail; xcodebuild build-for-testing -project "$(IOS_PROJECT)" -scheme "$(IOS_SCHEME)" \
		-destination '$(IOS_DESTINATION)' -derivedDataPath "$(IOS_DERIVED)" \
		CODE_SIGNING_ALLOWED=NO | $(BEAUTIFY)

# Run the unit tests against the build produced by ios-build.
ios-test: ios-build
	set -o pipefail; xcodebuild test-without-building -project "$(IOS_PROJECT)" -scheme "$(IOS_SCHEME)" \
		-destination '$(IOS_DESTINATION)' -derivedDataPath "$(IOS_DERIVED)" \
		CODE_SIGNING_ALLOWED=NO | $(BEAUTIFY)

# Build, install, and launch on the iOS Simulator. Boots the target simulator
# and opens Simulator.app if it isn't already running.
# Pass ARGS to forward launch arguments, e.g. ARGS=-autostart.
ios-run: ios-generate
	xcrun simctl boot "$(IOS_SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	xcodebuild build -project "$(IOS_PROJECT)" -scheme "$(IOS_SCHEME)" \
		-destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' -derivedDataPath "$(IOS_DERIVED)"
	xcrun simctl install booted "$(IOS_DERIVED)/Build/Products/Debug-iphonesimulator/$(IOS_APP_NAME).app"
	xcrun simctl terminate booted "$(IOS_BUNDLE_ID)" 2>/dev/null || true
	xcrun simctl launch booted "$(IOS_BUNDLE_ID)" $(ARGS)

# Build a Debug build, then install + launch on a connected iPhone.
# The device is auto-detected; override with IOS_DEVICE=<name-or-udid>.
# Heating, battery readings and thermal state only work here — the simulator
# borrows the Mac's CPU and reports no battery.
ios-deploy: ios-generate
	@DEVICE="$(IOS_DEVICE)"; \
	if [ -z "$$DEVICE" ]; then \
		DEVICE=$$(xcrun devicectl list devices 2>/dev/null | awk '{ ok=0; for (i=1;i<=NF;i++) if ($$i=="connected") ok=1; if (ok) for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]/) {print $$i; exit} }'); \
	fi; \
	if [ -z "$$DEVICE" ]; then \
		echo "No connected device found. Connect and trust a device, or pass IOS_DEVICE=<name-or-udid>."; \
		exit 1; \
	fi; \
	echo "Deploying to device: $$DEVICE"; \
	xcodebuild build -project "$(IOS_PROJECT)" -scheme "$(IOS_SCHEME)" \
		-destination "id=$$DEVICE" -derivedDataPath "$(IOS_DERIVED_DEVICE)" \
		-allowProvisioningUpdates DEVELOPMENT_TEAM=$(IOS_TEAM) && \
	xcrun devicectl device install app --device "$$DEVICE" \
		"$(IOS_DERIVED_DEVICE)/Build/Products/Debug-iphoneos/$(IOS_APP_NAME).app" && \
	xcrun devicectl device process launch --device "$$DEVICE" "$(IOS_BUNDLE_ID)"

# Archive for the App Store and upload to TestFlight. Prefer this over
# ios-deploy for anything you want to keep using: a development build stops
# launching when its provisioning profile expires, a TestFlight build lasts 90
# days and is replaced by simply uploading again.
#
# One-time setup (App Store Connect API key + app record) is in README.md.
# The build number comes from the commit count; override with BUILD_NUMBER=<n>.
testflight:
	@./scripts/testflight.sh

# Same pipeline, stopping at App Store Connect's validation — use it to check a
# change signs and passes the automated checks without burning a build number.
testflight-validate:
	@./scripts/testflight.sh --validate

# Just produce the signed .ipa in build-archive/, without uploading it. Still
# needs the distribution signing assets, so run it after the one-time setup.
ios-archive:
	@./scripts/testflight.sh --archive

# Screenshot a connected device or a booted Simulator, whichever is available
# (a connected device must be unlocked). When several targets are available the
# script lists them and exits rather than guessing; pick one with:
#   make ios-screenshot TARGET=device
#   make ios-screenshot TARGET=simulator
#   make ios-screenshot SIM="iPhone 17 Pro"   # name or udid; implies simulator
#   make ios-screenshot DEV=<udid>            # implies device
# Override the destination with OUT=<path>; defaults to a timestamped /tmp file.
# Device capture needs: uv tool install pymobiledevice3
# SIM/DEV are quoted here rather than passed through a bare $(ARGS), so names
# containing spaces survive as a single argument.
ios-screenshot:
	@./scripts/ios_screenshot.sh $(if $(TARGET),--$(TARGET)) \
		$(if $(SIM),--simulator="$(SIM)") $(if $(DEV),--device="$(DEV)") "$(OUT)"

# Format Swift sources in place with Apple's swift-format (bundled with Xcode).
# Style comes from .swift-format at the repo root.
format-ios:
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format format --in-place --recursive HandWarmer HandWarmerTests; \
	else \
		echo "Skipping format-ios (swift-format not found — needs macOS + Xcode)"; \
	fi

# SwiftLint owns the semantic rules (naming, complexity, line length); config is
# .swiftlint.yml. --strict promotes warnings to errors so nothing merges dirty.
lint-ios:
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint not found. Install it with: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet --strict

# Run SwiftLint (via the prerequisite above), then lint formatting without
# changing anything. This is what CI gates on.
check-ios: lint-ios
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format lint --strict --recursive HandWarmer HandWarmerTests; \
	else \
		echo "Skipping swift-format lint (not found — needs macOS + Xcode)"; \
	fi

clean:
	rm -rf "$(IOS_DERIVED)" "$(IOS_DERIVED_DEVICE)" build-archive

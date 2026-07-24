# Makefile for building, deploying and screenshotting Hand Warmer.
# Ported from the pussel repo's iOS targets.
#
# Config knobs — override on the command line, e.g.
#   make ios-run IOS_SIMULATOR="iPhone 17 Pro Max"
#   make ios-deploy IOS_DEVICE=<name-or-udid>

.PHONY: ios-generate ios-run ios-deploy ios-screenshot format-ios check-ios clean

IOS_SCHEME     = HandWarmer
# Built product name (<IOS_APP_NAME>.app). Keep it in sync with IOS_SCHEME's
# target PRODUCT_NAME if you override the scheme.
IOS_APP_NAME   = HandWarmer
IOS_BUNDLE_ID  = com.claus.HandWarmer
IOS_PROJECT    = HandWarmer.xcodeproj
IOS_SIMULATOR ?= iPhone 17 Pro
IOS_DERIVED    = build
IOS_DERIVED_DEVICE = build-device

# Apple Developer team used for device signing. Automatic signing cannot pick a
# team on its own from the command line, so it must be named here; override with
# `make ios-deploy IOS_TEAM=XXXXXXXXXX` if you build under a different account.
IOS_TEAM ?= RS2FKJW2W4

# Regenerate the (gitignored) Xcode project from project.yml.
# Requires `brew install xcodegen`.
ios-generate:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	xcodegen generate

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
format-ios:
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format format --in-place --recursive HandWarmer; \
	else \
		echo "Skipping format-ios (swift-format not found — needs macOS + Xcode)"; \
	fi

# Lint formatting without changing anything.
check-ios:
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format lint --strict --recursive HandWarmer; \
	else \
		echo "Skipping check-ios (swift-format not found — needs macOS + Xcode)"; \
	fi

clean:
	rm -rf "$(IOS_DERIVED)" "$(IOS_DERIVED_DEVICE)"

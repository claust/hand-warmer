#!/usr/bin/env bash
#
# Archive Hand Warmer for the App Store and upload it to TestFlight.
#
# This replaces `make ios-deploy` as the way to get the app onto a phone.
# Development builds are signed with a provisioning profile that expires (and
# then iOS refuses to launch the app — "no longer available"); a TestFlight
# build is signed for distribution and installs through the TestFlight app,
# which nags for an update instead of dying.
#
# Configuration is read from the environment, falling back to .testflight.env
# at the repo root (gitignored — it names your API key, which is a credential).
# See README.md § TestFlight for the one-time App Store Connect setup.
#
# Usage:
#   scripts/testflight.sh              # archive, export, upload
#   scripts/testflight.sh --validate   # everything except the upload
#   scripts/testflight.sh --archive    # stop after producing the .ipa

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# Load the local, gitignored config first so real environment variables still
# win over it (handy in CI, where the values arrive as secrets).
if [ -f "$ROOT/.testflight.env" ]; then
	# shellcheck disable=SC1091
	set -a && . "$ROOT/.testflight.env" && set +a
fi

SCHEME="${IOS_SCHEME:-HandWarmer}"
PROJECT="${IOS_PROJECT:-HandWarmer.xcodeproj}"
TEAM="${IOS_TEAM:-RS2FKJW2W4}"
ARCHIVE_DIR="${IOS_ARCHIVE_DIR:-build-archive}"

# CFBundleVersion has to increase with every upload or App Store Connect rejects
# the build as a duplicate. The commit count is monotonic on master and needs no
# state outside git, so it beats a hand-bumped number in project.yml. Override
# with BUILD_NUMBER=<n> when uploading from a branch whose count has drifted.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

MODE=upload
case "${1:-}" in
	--validate) MODE=validate ;;
	--archive) MODE=archive ;;
	"") ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# --- API key -----------------------------------------------------------------
# altool and xcodebuild both authenticate with an App Store Connect API key: an
# issuer UUID, a key ID, and the .p8 private key that Apple lets you download
# exactly once. Everything but the .p8 itself lives in .testflight.env; the .p8
# goes in ~/.private_keys, which is where altool looks by default.
need() {
	if [ -z "${!1:-}" ]; then
		echo "Missing $1. Set it in .testflight.env — see README.md § TestFlight." >&2
		exit 1
	fi
}

if [ "$MODE" != archive ]; then
	need ASC_KEY_ID
	need ASC_ISSUER_ID
fi

KEY_PATH=""
if [ -n "${ASC_KEY_ID:-}" ]; then
	for dir in "$ROOT/private_keys" "$HOME/private_keys" "$HOME/.private_keys" \
		"$HOME/.appstoreconnect/private_keys"; do
		if [ -f "$dir/AuthKey_$ASC_KEY_ID.p8" ]; then
			KEY_PATH="$dir/AuthKey_$ASC_KEY_ID.p8"
			break
		fi
	done
	if [ -z "$KEY_PATH" ] && [ "$MODE" != archive ]; then
		echo "Could not find AuthKey_$ASC_KEY_ID.p8 in ~/.private_keys (or ./private_keys)." >&2
		echo "Download it from App Store Connect → Users and Access → Integrations." >&2
		exit 1
	fi
fi

# --- build -------------------------------------------------------------------
BEAUTIFY="cat"
command -v xcbeautify >/dev/null 2>&1 && BEAUTIFY=xcbeautify

echo "==> Generating Xcode project"
xcodegen generate

ARCHIVE="$ARCHIVE_DIR/$SCHEME.xcarchive"
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"

# Signing assets are created on demand: -allowProvisioningUpdates lets xcodebuild
# register the two bundle IDs (app + widget extension) and mint the distribution
# profiles the first time through, so nothing has to be clicked in the portal.
# It needs the API key to do that, hence the -authenticationKey* flags.
AUTH=()
if [ -n "$KEY_PATH" ]; then
	AUTH=(-authenticationKeyPath "$KEY_PATH"
		-authenticationKeyID "$ASC_KEY_ID"
		-authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "==> Archiving $SCHEME (build $BUILD_NUMBER)"
set -o pipefail
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE" \
	-allowProvisioningUpdates \
	${AUTH[@]+"${AUTH[@]}"} \
	DEVELOPMENT_TEAM="$TEAM" \
	CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	| $BEAUTIFY

# manageAppVersionAndBuildNumber=false keeps Xcode from silently rewriting the
# build number we just set; we own it, via the commit count.
cat > "$ARCHIVE_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Exporting .ipa"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportPath "$ARCHIVE_DIR" \
	-exportOptionsPlist "$ARCHIVE_DIR/ExportOptions.plist" \
	-allowProvisioningUpdates \
	${AUTH[@]+"${AUTH[@]}"} \
	| $BEAUTIFY

IPA="$(find "$ARCHIVE_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$IPA" ] || { echo "Export produced no .ipa" >&2; exit 1; }
echo "==> Built $IPA"

if [ "$MODE" = archive ]; then
	exit 0
fi

# --- upload ------------------------------------------------------------------
# Validation catches the cheap rejections (missing icon, bad entitlements, a
# build number App Store Connect has already seen) before spending the upload.
echo "==> Validating with App Store Connect"
xcrun altool --validate-app -f "$IPA" -t ios \
	--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

if [ "$MODE" = validate ]; then
	echo "==> Validation passed (upload skipped)"
	exit 0
fi

echo "==> Uploading to TestFlight"
xcrun altool --upload-app -f "$IPA" -t ios \
	--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "Uploaded build $BUILD_NUMBER. App Store Connect takes a few minutes to"
echo "finish processing before it shows up in TestFlight on the phone."

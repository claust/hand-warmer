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

# Fill in only what the environment has not already set, so CI — where the
# values arrive as secrets — wins over a stale local file. Sourcing the file
# outright would do the opposite and silently override the secrets.
if [ -f "$ROOT/.testflight.env" ]; then
	while IFS='=' read -r key value; do
		# Skip blanks and comments, then anything that is not a plain shell
		# identifier. The file is hand-edited, so a stray line should be
		# ignored rather than turned into an assignment — and refusing to
		# expand arbitrary names keeps the lookup below from being a way to
		# smuggle in shell.
		case "$key" in
			'' | \#*) continue ;;
			[!A-Za-z_]* | *[!A-Za-z0-9_]*) continue ;;
		esac
		# A file saved with CRLF line endings would otherwise carry the \r
		# into the value, and a key id with a trailing carriage return fails
		# authentication in a way that reads as "wrong credentials".
		value=${value%$'\r'}
		# Indirect expansion rather than eval: same "is it already set?"
		# question, no shell constructed from file contents.
		[ -z "${!key:-}" ] && export "$key=$value"
	done < "$ROOT/.testflight.env"
fi

SCHEME="${IOS_SCHEME:-HandWarmer}"
PROJECT="${IOS_PROJECT:-HandWarmer.xcodeproj}"
TEAM="${IOS_TEAM:-RS2FKJW2W4}"
ARCHIVE_DIR="${IOS_ARCHIVE_DIR:-build-archive}"

# This directory is wiped with `rm -rf` further down, so refuse anything that
# could resolve outside the repo or at the repo root itself. It is a
# convenience knob rather than untrusted input, but that is exactly the kind of
# variable that ends up holding a mistyped absolute path one day — and the cost
# of being wrong here is somebody's home directory, not a failed build.
case "$ARCHIVE_DIR" in
	'' | '.' | '..' | /* | ~*)
		echo "IOS_ARCHIVE_DIR must be a relative path below the repo root; got '$ARCHIVE_DIR'." >&2
		exit 2 ;;
	*/../* | ../* | */..)
		echo "IOS_ARCHIVE_DIR must not escape the repo root; got '$ARCHIVE_DIR'." >&2
		exit 2 ;;
esac

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
# exactly once. Locally those ids come from .testflight.env; in CI they arrive
# as repository secrets in the environment. The .p8 itself goes in
# ~/.private_keys, which is where altool looks by default.
need() {
	if [ -z "${!1:-}" ]; then
		echo "Missing $1. Set it in the environment (CI: repository secrets) or" >&2
		echo "in .testflight.env locally — see README.md § TestFlight." >&2
		exit 1
	fi
}

# Required in every mode, --archive included. Archiving signs for distribution
# via -allowProvisioningUpdates, which needs the key to register bundle ids and
# mint the certificate and profiles — without it xcodebuild fails much later
# with "No Accounts: Add a new account in Accounts settings" and "No profiles
# for '<bundle id>' were found", which sends you looking at Xcode rather than at
# the credential that is actually missing.
need ASC_KEY_ID
need ASC_ISSUER_ID

KEY_PATH=""
for dir in "$ROOT/private_keys" "$HOME/private_keys" "$HOME/.private_keys" \
	"$HOME/.appstoreconnect/private_keys"; do
	if [ -f "$dir/AuthKey_$ASC_KEY_ID.p8" ]; then
		KEY_PATH="$dir/AuthKey_$ASC_KEY_ID.p8"
		break
	fi
done
if [ -z "$KEY_PATH" ]; then
	echo "Could not find AuthKey_$ASC_KEY_ID.p8 in ~/.private_keys (or ./private_keys)." >&2
	echo "Download it from App Store Connect → Users and Access → Integrations." >&2
	exit 1
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
AUTH=(-authenticationKeyPath "$KEY_PATH"
	-authenticationKeyID "$ASC_KEY_ID"
	-authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> Archiving $SCHEME (build $BUILD_NUMBER)"
set -o pipefail
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE" \
	-allowProvisioningUpdates \
	"${AUTH[@]}" \
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
	"${AUTH[@]}" \
	| $BEAUTIFY

# -print -quit rather than piping to head: head closes the pipe as soon as it
# has its line, find dies of SIGPIPE, and pipefail makes 141 the status of the
# assignment — which set -e turns into an exit even though the .ipa is right
# there. It survives today only because this directory holds one file.
IPA="$(find "$ARCHIVE_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
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

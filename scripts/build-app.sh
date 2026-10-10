#!/bin/bash
# Build/sign a local bundle. Does not install services or change power settings.
set -euo pipefail
umask 022
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${DONT_SLEEP_BUILD_CONFIGURATION:-release}"
case "$CONFIGURATION" in release|debug) ;; *) echo "Invalid configuration" >&2; exit 2 ;; esac
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
cd "$ROOT"
# Refuse stale security pins before compiling or packaging the installer.
INSTALLER_HASH="$(/usr/bin/shasum -a 256 scripts/install-helpers.sh | /usr/bin/awk '{print $1}')"
PINNED_HASH="$(/usr/bin/sed -n 's/.*static let pinnedSHA256 = "\([0-9a-f]*\)".*/\1/p' Sources/DontSleepApp/InstallerProgram.swift)"
if [ "$INSTALLER_HASH" != "$PINNED_HASH" ] || [ ${#PINNED_HASH} -ne 64 ]; then
  echo "Installer digest differs from reviewed app pin; review and update InstallerProgram before building." >&2
  exit 1
fi
/usr/bin/swift build --configuration "$CONFIGURATION" --arch arm64
BIN="$(/usr/bin/swift build --configuration "$CONFIGURATION" --arch arm64 --show-bin-path)"
DIST="$ROOT/dist"
/bin/mkdir -p "$DIST"
STAGE="$(/usr/bin/mktemp -d "$DIST/.bundle-build.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
APP="$STAGE/Don’t Sleep.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchServices" "$APP/Contents/Resources/launchd"
/bin/cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$BIN/DontSleepApp" "$APP/Contents/MacOS/DontSleepApp"
for NAME in DontSleepController DontSleepWatchdog; do
  /bin/cp "$BIN/$NAME" "$APP/Contents/Library/LaunchServices/$NAME"
done
/bin/cp "$ROOT/scripts/install-helpers.sh" "$APP/Contents/Resources/install-helpers.sh"
/bin/cp "$ROOT/scripts/uninstall-helpers.sh" "$APP/Contents/Resources/uninstall-helpers.sh"
for PLIST in "$ROOT"/Resources/launchd/*.plist; do
  /usr/bin/plutil -lint "$PLIST"
  /bin/cp "$PLIST" "$APP/Contents/Resources/launchd/"
done
if [ -f "$ROOT/Resources/Assets/AppIcon.icns" ]; then
  /bin/cp "$ROOT/Resources/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Missing Resources/Assets/AppIcon.icns" >&2
  exit 1
fi
/bin/chmod 755 "$APP/Contents/MacOS/DontSleepApp" "$APP/Contents/Library/LaunchServices/"* "$APP/Contents/Resources/"*.sh
/usr/bin/codesign --force --sign - --timestamp=none --options runtime --identifier local.dontsleep.controller "$APP/Contents/Library/LaunchServices/DontSleepController"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime --identifier local.dontsleep.watchdog "$APP/Contents/Library/LaunchServices/DontSleepWatchdog"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$APP"
"$ROOT/scripts/verify-bundle.sh" "$APP"
OUTPUT="$DIST/Don’t Sleep.app"
if [ -e "$OUTPUT" ]; then
  /bin/mkdir -p "$DIST/.previous"
  /bin/mv "$OUTPUT" "$DIST/.previous/Don’t Sleep.$(/bin/date +%Y%m%d-%H%M%S).app"
fi
/bin/mv "$APP" "$OUTPUT"
/usr/bin/printf 'Built: %s\n' "$OUTPUT"

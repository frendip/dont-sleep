#!/bin/bash
# Read-only integrity validation of a locally built bundle.
set -euo pipefail
APP="${1:?Usage: verify-bundle.sh /absolute/path/to/app}"
case "$APP" in /*.app) ;; *) echo "Expected absolute .app path" >&2; exit 2 ;; esac
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = local.dontsleep.app ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = true ]
for NAME in DontSleepController DontSleepWatchdog; do
  [ -x "$APP/Contents/Library/LaunchServices/$NAME" ]
  /usr/bin/codesign --verify --strict "$APP/Contents/Library/LaunchServices/$NAME"
  case "$NAME" in DontSleepController) EXPECTED=local.dontsleep.controller ;; DontSleepWatchdog) EXPECTED=local.dontsleep.watchdog ;; esac
  ID="$(/usr/bin/codesign -d --verbose=4 "$APP/Contents/Library/LaunchServices/$NAME" 2>&1 | /usr/bin/awk -F= '$1 == "Identifier" {print $2}')"
  [ "$ID" = "$EXPECTED" ]
done
[ -x "$APP/Contents/MacOS/DontSleepApp" ]
[ -f "$APP/Contents/Resources/install-helpers.sh" ]
[ -f "$APP/Contents/Resources/uninstall-helpers.sh" ]
[ -f "$APP/Contents/Resources/AppIcon.icns" ]
/bin/bash -n "$APP/Contents/Resources/install-helpers.sh"
/bin/bash -n "$APP/Contents/Resources/uninstall-helpers.sh"
"$APP/Contents/MacOS/DontSleepApp" --verify-installation-payload
/usr/bin/printf 'Bundle integrity and installer preparation verified; services were not installed.\n'

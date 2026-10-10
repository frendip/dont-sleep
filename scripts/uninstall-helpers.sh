#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
ROOT='/Library/Application Support/DontSleep'
fail() { echo "Don’t Sleep removal: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Administrator authorization is required.'
[[ $# -eq 0 ]] || fail 'This script accepts no paths or commands.'
secure_path() {
    local path=$1 mode permissions
    [[ -e "$path" && ! -L "$path" && $(/usr/bin/stat -f %u "$path") == 0 ]] || fail "Untrusted protected path: $path"
    mode=$(/usr/bin/stat -f %Lp "$path")
    (( (8#$mode & 0022) == 0 )) || fail "Writable protected path: $path"
    permissions=$(/bin/ls -lde "$path"); permissions=${permissions%% *}
    [[ $permissions != *+* ]] || fail "Unexpected ACL: $path"
}
for path in /Library '/Library/Application Support' /Library/LaunchDaemons "$ROOT" "$ROOT/bin" "$ROOT/trust.json" "$ROOT/bin/DontSleepController"; do secure_path "$path"; done
LOCK="$ROOT/.setup.lock"
if [[ -e "$LOCK" || -L "$LOCK" ]]; then secure_path "$LOCK"; [[ -f "$LOCK" ]] || fail 'Unexpected setup lock type.'; fi
# Descriptor-mode lockf locks the shared open-file description. The shell
# retains FD9 until exit; a crashed script cannot leave a stale held lock.
exec 9>> "$LOCK"
/usr/bin/lockf -t 0 9 || fail 'Another live setup/removal process holds the setup lock.' 
EXPECTED=$(/usr/bin/plutil -extract controller.cdhash raw "$ROOT/trust.json")
ACTUAL=$(/usr/bin/codesign -d --verbose=4 "$ROOT/bin/DontSleepController" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
[[ $EXPECTED =~ ^[0-9a-f]{40}$ && $ACTUAL == "$EXPECTED" ]] || fail 'Protected controller identity mismatch.'
/usr/bin/codesign --verify --strict "$ROOT/bin/DontSleepController"
if /bin/launchctl print system/local.dontsleep.controller >/dev/null 2>&1; then /bin/launchctl bootout system/local.dontsleep.controller; fi
if ! "$ROOT/bin/DontSleepController" --stop-and-check; then
    /bin/launchctl bootstrap system /Library/LaunchDaemons/local.dontsleep.controller.plist || true
    fail 'Restoration is not verified; helpers and journal retained.'
fi
if /bin/launchctl print system/local.dontsleep.watchdog >/dev/null 2>&1; then /bin/launchctl bootout system/local.dontsleep.watchdog; fi
for role in controller watchdog; do
    target="/Library/LaunchDaemons/local.dontsleep.$role.plist"
    secure_path "$target"
    /bin/rm "$target"
done
# Keep the state directory and restored journal as an audit/recovery record.
# Keeping the pinned binaries/trust also makes repair possible after interruption.
echo 'Helpers unloaded and launchd registrations removed. Protected recovery records retained.'

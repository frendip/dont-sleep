#!/bin/bash
# Explicit administrator setup only. Building the app never runs this script.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
ROOT='/Library/Application Support/DontSleep'
fail() { echo "Don’t Sleep setup: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Administrator authorization is required.'
[[ $# -eq 5 && $2 == --uid && $4 == --expected-app-hash ]] || fail 'Usage: install-helpers.sh /absolute/App.app --uid USER_UID --expected-app-hash LIVE_CDHASH'
APP=$1
AUTHORIZED_UID=$3
EXPECTED_APP_HASH=$5
[[ $EXPECTED_APP_HASH =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid expected application identity.'
[[ $APP == /* && -d "$APP" && ! -L "$APP" ]] || fail 'App must be an absolute, real directory.'
[[ $AUTHORIZED_UID =~ ^[1-9][0-9]{2,9}$ ]] || fail 'Invalid authorized user UID.'
(( AUTHORIZED_UID >= 501 && AUTHORIZED_UID <= 4294967294 )) || fail 'A non-system user UID is required.'
secure_path() {
    local path=$1 owner mode permissions
    [[ -e "$path" && ! -L "$path" ]] || fail "Missing or symbolic-link protected path: $path"
    owner=$(/usr/bin/stat -f %u "$path")
    mode=$(/usr/bin/stat -f %Lp "$path")
    [[ $owner == 0 ]] || fail "Protected path is not root-owned: $path"
    (( (8#$mode & 0022) == 0 )) || fail "Protected path is writable by others: $path"
    permissions=$(/bin/ls -lde "$path")
    permissions=${permissions%% *}
    [[ $permissions != *+* ]] || fail "Unexpected ACL on protected path: $path"
}
for path in /Library '/Library/Application Support' /Library/LaunchDaemons; do secure_path "$path"; done
if [[ ! -e "$ROOT" && ! -L "$ROOT" ]]; then /bin/mkdir -m 755 "$ROOT"; fi
secure_path "$ROOT"
if [[ ! -e "$ROOT/state" && ! -L "$ROOT/state" ]]; then /bin/mkdir -m 700 "$ROOT/state"; fi
secure_path "$ROOT/state"
[[ $(/usr/bin/stat -f %Lp "$ROOT/state") == 700 ]] || fail 'Recovery state directory must have mode 0700.'
for item in bin trust.json; do
    if [[ -e "$ROOT/$item" || -L "$ROOT/$item" ]]; then secure_path "$ROOT/$item"; fi
done
LOCK="$ROOT/.setup.lock"
if [[ -e "$LOCK" || -L "$LOCK" ]]; then
    secure_path "$LOCK"; [[ -f "$LOCK" ]] || fail 'Unexpected setup lock type.'
fi
# Descriptor-mode lockf locks the shared open-file description. The shell
# retains FD9 until exit; a crashed script cannot leave a stale held lock.
exec 9>> "$LOCK"
/usr/bin/lockf -t 0 9 || fail 'Another live setup/removal process holds the setup lock.' 
STAGE=''
cleanup() {
    if [[ -n $STAGE && $STAGE == "$ROOT"/.stage.* ]]; then /bin/rm -rf "$STAGE"; fi
}
trap cleanup EXIT
STAGE=$(/usr/bin/mktemp -d "$ROOT/.stage.XXXXXX")
/bin/mkdir -m 755 "$STAGE/bin"
copy_code() {
    local source=$1 name=$2 identifier=$3 details hash actual
    [[ -f "$source" && ! -L "$source" ]] || fail "Missing regular executable: $source"
    /bin/cp -X "$source" "$STAGE/bin/$name"
    /usr/sbin/chown root:wheel "$STAGE/bin/$name"
    /bin/chmod 755 "$STAGE/bin/$name"
    /usr/bin/codesign --verify --strict "$STAGE/bin/$name" || fail "Invalid code signature: $name"
    details=$(/usr/bin/codesign -d --verbose=4 "$STAGE/bin/$name" 2>&1)
    actual=$(echo "$details" | /usr/bin/awk -F= '$1 == "Identifier" {print $2}')
    hash=$(echo "$details" | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
    [[ $actual == "$identifier" && $hash =~ ^[0-9a-f]{40}$ ]] || fail "Unexpected identity: $name"
    [[ $details == *'runtime'* ]] || fail "Hardened runtime signature required: $name"
    printf '%s' "$hash"
}
# A bundle signature includes Info.plist/resource slots: a bare copy of the GUI
# executable is not independently verifiable. Preserve the complete signed app.
[[ -z $(/usr/bin/find "$APP" -type l -print -quit) ]] || fail 'Symbolic links are not accepted in the app bundle.'
/usr/bin/ditto --noextattr --noacl --norsrc "$APP" "$STAGE/bin/DontSleepApp.app"
[[ -z $(/usr/bin/find "$STAGE/bin/DontSleepApp.app" -type l -print -quit) ]] || fail 'Copied app contains a symbolic link.'
/usr/sbin/chown -R root:wheel "$STAGE/bin/DontSleepApp.app"
/bin/chmod -R go-w "$STAGE/bin/DontSleepApp.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/bin/DontSleepApp.app"
APP_DETAILS=$(/usr/bin/codesign -d --verbose=4 "$STAGE/bin/DontSleepApp.app" 2>&1)
APP_IDENTIFIER=$(echo "$APP_DETAILS" | /usr/bin/awk -F= '$1 == "Identifier" {print $2}')
APP_HASH=$(echo "$APP_DETAILS" | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
[[ $APP_IDENTIFIER == local.dontsleep.app && $APP_HASH == "$EXPECTED_APP_HASH" && $APP_DETAILS == *runtime* ]] || fail 'Unexpected GUI code identity.'

CONTROLLER_HASH=$(copy_code "$STAGE/bin/DontSleepApp.app/Contents/Library/LaunchServices/DontSleepController" DontSleepController local.dontsleep.controller)
WATCHDOG_HASH=$(copy_code "$STAGE/bin/DontSleepApp.app/Contents/Library/LaunchServices/DontSleepWatchdog" DontSleepWatchdog local.dontsleep.watchdog)
cat > "$STAGE/trust.json" <<JSON
{"version":1,"authorizedUID":$AUTHORIZED_UID,"app":{"identifier":"local.dontsleep.app","cdhash":"$APP_HASH"},"controller":{"identifier":"local.dontsleep.controller","cdhash":"$CONTROLLER_HASH"},"watchdog":{"identifier":"local.dontsleep.watchdog","cdhash":"$WATCHDOG_HASH"}}
JSON
/bin/chmod 644 "$STAGE/trust.json"
for role in controller watchdog; do
    if [[ $role == controller ]]; then binary=DontSleepController; else binary=DontSleepWatchdog; fi
    cat > "$STAGE/local.dontsleep.$role.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.dontsleep.$role</string>
<key>ProgramArguments</key><array><string>$ROOT/bin/$binary</string></array>
<key>MachServices</key><dict><key>local.dontsleep.$role</key><true/></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string><key>ThrottleInterval</key><integer>10</integer>
<key>Umask</key><integer>63</integer>
</dict></plist>
PLIST
    /bin/chmod 644 "$STAGE/local.dontsleep.$role.plist"
done
# A completed old pair is retained until a later successful setup. Repair an
# interrupted bin/trust publication only while both fixed jobs are unloaded.
pair_matches() (
    local directory=$1 manifest=$2 role name expected actual
    secure_path "$directory"; secure_path "$manifest"
    for role in controller watchdog; do
        if [[ $role == controller ]]; then name=DontSleepController; else name=DontSleepWatchdog; fi
        secure_path "$directory/$name"
        expected=$(/usr/bin/plutil -extract "$role.cdhash" raw "$manifest")
        actual=$(/usr/bin/codesign -d --verbose=4 "$directory/$name" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
        [[ $expected =~ ^[0-9a-f]{40}$ && $actual == "$expected" ]] || exit 1
        /usr/bin/codesign --verify --strict "$directory/$name" || exit 1
    done
)
if [[ -e "$ROOT/previous-bin" && -e "$ROOT/previous-trust.json" ]]; then
    if ! pair_matches "$ROOT/bin" "$ROOT/trust.json"; then
        ! /bin/launchctl print system/local.dontsleep.controller >/dev/null 2>&1 || fail 'Cannot repair publication while Controller is loaded.'
        ! /bin/launchctl print system/local.dontsleep.watchdog >/dev/null 2>&1 || fail 'Cannot repair publication while Watchdog is loaded.'
        pair_matches "$ROOT/previous-bin" "$ROOT/previous-trust.json" || fail 'Previous protected identity pair is invalid; preserve recovery records.'
        /usr/bin/ditto --noextattr --noacl --norsrc "$ROOT/previous-bin" "$STAGE/repair-bin"
        /bin/cp -X "$ROOT/previous-trust.json" "$STAGE/repair-trust.json"
        pair_matches "$STAGE/repair-bin" "$STAGE/repair-trust.json" || fail 'Protected repair copy failed verification.'
        if [[ -e "$ROOT/bin" ]]; then /bin/mv "$ROOT/bin" "$STAGE/interrupted-bin"; fi
        /bin/mv "$STAGE/repair-bin" "$ROOT/bin"
        /bin/mv -f "$STAGE/repair-trust.json" "$ROOT/trust.json"
        /bin/sync
    fi
fi
# Stop the public broker FIRST: new UI starts cannot race maintenance.
if /bin/launchctl print system/local.dontsleep.controller >/dev/null 2>&1; then
    /bin/launchctl bootout system/local.dontsleep.controller
fi
if [[ -f "$ROOT/trust.json" ]]; then
    secure_path "$ROOT/bin/DontSleepController"
    EXPECTED=$(/usr/bin/plutil -extract controller.cdhash raw "$ROOT/trust.json")
    ACTUAL=$(/usr/bin/codesign -d --verbose=4 "$ROOT/bin/DontSleepController" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
    [[ $EXPECTED =~ ^[0-9a-f]{40}$ && $ACTUAL == "$EXPECTED" ]] || fail 'Old controller does not match protected trust.'
    /usr/bin/codesign --verify --strict "$ROOT/bin/DontSleepController"
    if /bin/launchctl print system/local.dontsleep.watchdog >/dev/null 2>&1; then
        if ! "$ROOT/bin/DontSleepController" --stop-and-check; then
            /bin/launchctl bootstrap system /Library/LaunchDaemons/local.dontsleep.controller.plist || true
            fail 'Cannot verify restoration. Existing helpers and recovery journal were retained.'
        fi
    else
        secure_path "$ROOT/bin/DontSleepWatchdog"
        EXPECTED=$(/usr/bin/plutil -extract watchdog.cdhash raw "$ROOT/trust.json")
        ACTUAL=$(/usr/bin/codesign -d --verbose=4 "$ROOT/bin/DontSleepWatchdog" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
        [[ $EXPECTED =~ ^[0-9a-f]{40}$ && $ACTUAL == "$EXPECTED" ]] || fail 'Old watchdog does not match protected trust.'
        /usr/bin/codesign --verify --strict "$ROOT/bin/DontSleepWatchdog"
        "$ROOT/bin/DontSleepWatchdog" --recover-and-check || fail 'Offline recovery failed; existing files retained.'
    fi
elif [[ -e "$ROOT/state/recovery.json" || -L "$ROOT/state/recovery.json" ]]; then
    fail 'Recovery journal exists without established trust. Preserve it and repair recovery first.'
fi
if /bin/launchctl print system/local.dontsleep.watchdog >/dev/null 2>&1; then
    /bin/launchctl bootout system/local.dontsleep.watchdog
fi
# Both jobs are stopped and the prior mutation is verified restored. A crash
# during replacement leaves services unavailable; it cannot re-enable power.
# These backups are protected, never launched automatically, and survive an
# interrupted publication. The next setup validates both pins before repair.
for backup in previous-bin previous-trust.json; do
    if [[ -e "$ROOT/$backup" || -L "$ROOT/$backup" ]]; then
        secure_path "$ROOT/$backup"; /bin/rm -rf "$ROOT/$backup"
    fi
done
if [[ -f "$ROOT/trust.json" ]]; then
    /bin/cp -X "$ROOT/trust.json" "$ROOT/previous-trust.json"
    /bin/chmod 644 "$ROOT/previous-trust.json"
    /bin/mv "$ROOT/bin" "$ROOT/previous-bin"
elif [[ -e "$ROOT/bin" ]]; then
    /bin/mv "$ROOT/bin" "$STAGE/unused-bin"
fi
/bin/sync
/bin/mv "$STAGE/bin" "$ROOT/bin"
/bin/mv -f "$STAGE/trust.json" "$ROOT/trust.json"
for role in controller watchdog; do
    destination="/Library/LaunchDaemons/local.dontsleep.$role.plist"
    if [[ -e "$destination" || -L "$destination" ]]; then secure_path "$destination"; fi
    /bin/mv -f "$STAGE/local.dontsleep.$role.plist" "$destination"
done
/bin/sync
/bin/launchctl bootstrap system /Library/LaunchDaemons/local.dontsleep.watchdog.plist
/bin/launchctl bootstrap system /Library/LaunchDaemons/local.dontsleep.controller.plist
# A reply from both authenticated services is checked by the app after setup.
echo 'Helpers installed. Open Don’t Sleep to verify service status.'

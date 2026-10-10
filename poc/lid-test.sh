#!/bin/bash
# Disposable AC or battery probe. Run --check first. No recovery across reboot.
DURATION=600
URL='https://www.apple.com/library/test/success.html'
LOCK_DIR='/private/var/run/agent-awake-probe.lock'
root_state() { /usr/sbin/ioreg -r -c IOPMrootDomain -d 1; }
flag() { /usr/bin/awk -v key="\"$1\"" '$1 == key {print $3}'; }
sleep_state() { root_state | flag SleepDisabled; }
power_write() { /usr/bin/pmset -a disablesleep "$1"; }
now_seconds() { /bin/date +%s; }
pause() { /bin/sleep "$1"; }
power_snapshot() { LC_ALL=C /usr/bin/pmset -g batt; }
parse_power_snapshot() {
  /usr/bin/awk '
    /^Now drawing from / {
      headers++
      if ($0 == "Now drawing from \047AC Power\047") source="ac"
      if ($0 == "Now drawing from \047Battery Power\047") source="battery"
    }
    /^[[:space:]]*-InternalBattery-[0-9]+[[:space:]]/ {
      batteries++
      if (index($0, "present: true")) present++
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+%;$/) {
          percentages++; token=$i; sub(/%;$/, "", token); percent=token+0
        }
      }
    }
    END {
      if (headers != 1 || source == "" || batteries != 1 || present != 1 ||
          percentages != 1 || percent < 0 || percent > 100) exit 1
      print source, percent
    }'
}
power_sample() {
  local snapshot
  snapshot=$(power_snapshot) || return 1
  printf '%s\n' "$snapshot" | parse_power_snapshot
}
power_allowed() {
  local mode=$1 sample source percent
  sample=$(power_sample) || { echo 'STOP: cannot read reliable power/battery data.' >&2; return 1; }
  read -r source percent <<< "$sample"
  [ "$source" = "$mode" ] || { echo "STOP: expected $mode power, observed $source." >&2; return 1; }
  case "$mode" in
    ac) return 0 ;;
    battery)
      [ "$percent" -gt 20 ] || { echo "STOP: battery at $percent%; restoring sleep at 20% or below." >&2; return 1; }
      ;;
    *) echo 'STOP: unknown power mode.' >&2; return 1 ;;
  esac
}
keep_awake() { /usr/bin/caffeinate -i -t "$1" >/dev/null 2>&1 & }
launchctl_command() { /bin/launchctl "$@"; }
launch_watchdog() { launchctl_command bootstrap system "$1"; }
stop_watchdog() { launchctl_command bootout "system/$1"; }
write_watchdog_plist() {
  # These values are generated internally: numeric PID/deadline and mktemp path.
  local job_label=$1 dir=$2 deadline=$3 mode=${4:-ac}
  /bin/cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$job_label</string>
  <key>UserName</key><string>root</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>--noprofile</string><string>--norc</string>
    <string>$dir/watchdog.sh</string><string>$dir</string><string>$deadline</string><string>$mode</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardOutPath</key><string>$dir/watchdog.log</string>
  <key>StandardErrorPath</key><string>$dir/watchdog.log</string>
</dict></plist>
PLIST
}
release_lock() {
  # Called only by the watchdog after submission; parent owns pre-submit cleanup.
  if [ -f "$LOCK_DIR/session" ] && [ "$(/bin/cat "$LOCK_DIR/session")" = "$1" ]; then
    /bin/rm -f "$LOCK_DIR/session"
    /bin/rmdir "$LOCK_DIR" || return 1
  fi
}
restore_sleep() {
  local attempt poll
  for attempt in 1 2 3; do
    # pmset exit status is insufficient: always read the actual kernel state.
    power_write 0 || true
    for poll in 1 2 3; do
      [ "$(sleep_state)" = No ] && return 0
      pause 1
    done
  done
  return 1
}
watchdog() {
  local dir=$1 deadline=$2 mode=${3:-ac} started_seconds=$SECONDS
  # A finished job may restart between recovery and housekeeping. Never let
  # it write power settings over a later session that acquired the lock.
  if [ -e "$dir/restored" ]; then
    release_lock "$dir"
    : > "$dir/done"
    return 0
  fi
  # Persist intent BEFORE mutation. Any unfinished restart goes to recovery.
  if [ ! -e "$dir/started" ] && [ ! -e "$dir/stop" ] &&
     [ "$(now_seconds)" -lt "$deadline" ] && power_allowed "$mode"; then
    : > "$dir/started"
    power_write 1 || true
    if [ "$(sleep_state)" = Yes ]; then
      keep_awake "$((deadline - $(now_seconds)))"
      : > "$dir/ready"
      while [ ! -e "$dir/stop" ] &&
            [ "$(now_seconds)" -lt "$deadline" ] &&
            [ "$((SECONDS - started_seconds))" -lt "$DURATION" ] && power_allowed "$mode"; do
        pause 1
      done
    fi
  fi
  # Retry verification after failure; never start a fresh ten-minute wait.
  : > "$dir/stop"
  until restore_sleep; do
    echo "$(now_seconds): RESTORE NOT CONFIRMED; retrying in five seconds."
    pause 5
  done
  echo "$(now_seconds): RESTORED: SleepDisabled=No"
  : > "$dir/restored"
  release_lock "$dir"
  : > "$dir/done"
}
network_request() {
  local stamp result status=0
  stamp=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
  result=$(/usr/bin/curl -q --fail --silent --show-error --connect-timeout 3 --max-time 4 \
    -H 'Cache-Control: no-cache' -o /dev/null -w '%{http_code}\t%{time_total}' \
    "$URL?probe=$(now_seconds)") || status=$?
  printf '%s\t%s\t%s\n' "$stamp" "$status" "$result"
}
network_worker() {
  local dir=$1 deadline=$2 started_seconds=$SECONDS
  # Independent limits: parent termination cannot leave this loop unbounded.
  while [ ! -e "$dir/stop" ] && [ ! -e "$dir/restored" ] &&
        [ "$(now_seconds)" -lt "$deadline" ] &&
        [ "$((SECONDS - started_seconds))" -lt "$DURATION" ]; do
    network_request
    pause 5
  done
}
check() {
  /usr/bin/sw_vers
  /usr/bin/pmset -g batt
  root_state | /usr/bin/awk '/"SleepDisabled"|"AppleClamshellState"/ {print}'
  /usr/bin/curl -q --fail --silent --show-error --connect-timeout 4 --max-time 8 "$URL"
  echo
}
# Sourcing defines reusable worker logic only; never launches privileged work.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 022
case "${1:---check}" in
  --check) check; exit 0 ;;
  --run) mode=ac ;;
  --run-battery) mode=battery ;;
  *) echo 'Usage: lid-test.sh --check | --run | --run-battery'; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo 'Run --run with sudo in Terminal.'; exit 1; }
# /private/var/run is root-writable only; a stale lock blocks another mutation.
/bin/mkdir -m 700 "$LOCK_DIR" || { echo "STOP: another/incomplete session exists: $LOCK_DIR"; exit 1; }
run_dir=''
label="local.agent-awake.probe.$$"
submitted=0
cleanup() {
  local result=$? poll
  trap - EXIT INT TERM HUP
  set +e
  if [ -n "$run_dir" ]; then
    : > "$run_dir/stop"
    if [ "$submitted" = 1 ]; then
      # Only the watchdog writes power settings, preventing competing restores.
      for poll in {1..15}; do
        [ -e "$run_dir/done" ] && break
        pause 1
      done
      if [ -e "$run_dir/done" ]; then
        stop_watchdog "$label" 2>/dev/null
        echo 'Watchdog confirmed restoration; see watchdog.log.'
      else
        if [ "$(sleep_state)" = No ]; then
          echo 'Current state: sleep is allowed (SleepDisabled=No).'
        fi
        echo 'WATCHDOG CLEANUP NOT CONFIRMED. Job and lock retained for inspection.' 
        echo 'Keep the lid open. Recovery command: sudo pmset -a disablesleep 0'
        result=1
      fi
    else
      release_lock "$run_dir"
    fi
    root_state > "$run_dir/power-after.txt"
    /usr/bin/pmset -g custom > "$run_dir/pmset-after.txt"
    echo "Logs: $run_dir"
  else
    /bin/rmdir "$LOCK_DIR"
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
run_dir=$(/usr/bin/mktemp -d /private/tmp/agent-awake-test.XXXXXXXX)
printf '%s\n' "$run_dir" > "$LOCK_DIR/session"
/bin/chmod 755 "$run_dir"
exec > >(/usr/bin/tee -a "$run_dir/session.log") 2>&1
state=$(root_state)
[ "$(printf '%s\n' "$state" | flag SleepDisabled)" = No ] || { echo 'STOP: baseline SleepDisabled is not No.'; exit 1; }
[ "$(printf '%s\n' "$state" | flag AppleClamshellState)" = No ] || { echo 'STOP: open the lid first.'; exit 1; }
power_allowed "$mode" || exit 1
printf '%s\n' "$mode" > "$run_dir/mode"
echo "Test mode: $mode; power sample: $(power_sample)"
/usr/bin/curl -q --fail --silent --show-error --connect-timeout 4 --max-time 8 "$URL" >/dev/null
/usr/bin/pmset -g custom > "$run_dir/pmset-before.txt"
printf '%s\n' "$state" > "$run_dir/power-before.txt"
/usr/bin/plutil -convert xml1 -o "$run_dir/preferences-before.xml" /Library/Preferences/com.apple.PowerManagement.plist
deadline=$(( $(now_seconds) + DURATION ))
printf '%s\n' "$deadline" > "$run_dir/deadline"
# Launch a root-owned immutable-for-unprivileged-users snapshot, not the checkout.
{
  printf '%s\n' '#!/bin/bash' 'set -eu' 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' 'export PATH' 'DURATION=600' "LOCK_DIR='$LOCK_DIR'"
  declare -f root_state flag sleep_state power_write now_seconds pause power_snapshot parse_power_snapshot power_sample power_allowed keep_awake release_lock restore_sleep watchdog
  printf '%s\n' '[ "$(/usr/bin/id -u)" = 0 ] || { echo "STOP: watchdog requires root."; exit 77; }' 'watchdog "$1" "$2" "$3"'
} > "$run_dir/watchdog.sh"
/bin/chmod 700 "$run_dir/watchdog.sh"
# bootstrap targets system explicitly: sudo alone does not change the caller's
# GUI bootstrap domain. The plist stays in /private/tmp, not LaunchDaemons;
# this is still a transient job and does not provide recovery across reboot.
write_watchdog_plist "$label" "$run_dir" "$deadline" "$mode" > "$run_dir/watchdog.plist"
/usr/bin/plutil -lint "$run_dir/watchdog.plist"
printf '%s\n' "system/$label" > "$run_dir/service-target"
submitted=1
launch_watchdog "$run_dir/watchdog.plist"
for poll in {1..10}; do
  [ -e "$run_dir/ready" ] && break
  [ -e "$run_dir/restored" ] && break
  pause 1
done
[ -e "$run_dir/ready" ] && [ ! -e "$run_dir/stop" ] && [ "$(sleep_state)" = Yes ] || {
  echo 'STOP: watchdog did not confirm activation.'
  launchctl_command print "system/$label" > "$run_dir/launchd-status.txt" 2>&1 || true
  if [ -f "$run_dir/watchdog.log" ]; then /bin/cat "$run_dir/watchdog.log"; fi
  exit 1;
}
network_worker "$run_dir" "$deadline" > "$run_dir/network.tsv" 2> "$run_dir/network-errors.log" &
printf 'time_utc\tlid_closed\tsleep_disabled\n' > "$run_dir/heartbeat.tsv"
echo "READY. Logs: $run_dir"
echo 'Lock screen with Control-Command-Q; close lid for 5 minutes, then reopen.'
if [ "$mode" = battery ]; then
  echo 'Keep charger disconnected. Battery at 20% or below stops the test.'
else
  echo 'Keep AC connected.'
fi
echo 'Press Control-C after reopening to request restoration.'
echo 'Watchdog restores sleep at deadline, on power-source change or invalid battery data.' 
echo 'Do not reboot: this temporary watchdog does not survive reboot.'
started_seconds=$SECONDS
while [ ! -e "$run_dir/stop" ] && [ "$(now_seconds)" -lt "$deadline" ] &&
      [ "$((SECONDS - started_seconds))" -lt "$DURATION" ]; do
  state=$(root_state)
  printf '%s\t%s\t%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(printf '%s\n' "$state" | flag AppleClamshellState)" "$(printf '%s\n' "$state" | flag SleepDisabled)" >> "$run_dir/heartbeat.tsv"
  /usr/bin/pmset -g batt >> "$run_dir/battery.log"
  [ "$(printf '%s\n' "$state" | flag SleepDisabled)" = Yes ] || break
  pause 5
done

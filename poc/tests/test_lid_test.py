"""Run Bash recovery logic with fake OS boundaries; never change Mac settings."""
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'lid-test.sh'
HARNESS = r'''
set -- --library
source "$PROBE_SCRIPT"
set -eu
cd "$CASE_DIR"
printf 'Yes\n' > state
printf '0\n' > clock
power_write() { echo "$1" >> writes; if [ "$1" = 0 ]; then echo No > state; else echo Yes > state; fi; }
sleep_state() { cat state; }
power_snapshot() { printf "Now drawing from 'AC Power'\n -InternalBattery-0 (id=123)\t100%%; charged; 0:00 remaining present: true\n"; }
now_seconds() { cat clock; }
pause() { echo "$(( $(cat clock) + 1 ))" > clock; }
keep_awake() { :; }
network_request() { echo request >> requests; }
'''

class RecoveryTests(unittest.TestCase):
    def run_case(self, code):
        with tempfile.TemporaryDirectory() as d:
            result = subprocess.run(['/bin/bash', '-c', HARNESS + code],
                env={**os.environ, 'PROBE_SCRIPT': str(SCRIPT), 'CASE_DIR': d},
                text=True, capture_output=True, timeout=8)
            files = {p.name: p.read_text() for p in Path(d).iterdir() if p.is_file()}
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return files, result.stdout

    def test_zero_exit_without_state_change_is_not_restore_success(self):
        files, out = self.run_case(r'''
power_write() { echo attempt >> writes; return 0; }
if restore_sleep; then echo unsafe-success; else echo restore-failed; fi
''')
        self.assertIn('restore-failed', out)
        self.assertNotIn('unsafe-success', out)
        self.assertEqual(files['state'], 'Yes\n')

    def test_unknown_state_is_not_restore_success(self):
        _, out = self.run_case(r'''
sleep_state() { echo Unknown; }
if restore_sleep; then echo unsafe-success; else echo restore-failed; fi
''')
        self.assertIn('restore-failed', out)
        self.assertNotIn('unsafe-success', out)

    def test_restore_retries_until_state_changes(self):
        files, _ = self.run_case(r'''
power_write() {
  echo attempt >> writes
  if [ "$(wc -l < writes)" -ge 2 ]; then echo No > state; fi
  return 0
}
restore_sleep
''')
        self.assertEqual(files['state'], 'No\n')
        self.assertGreaterEqual(len(files['writes'].splitlines()), 2)

    def test_restart_recovers_immediately_without_reenabling_or_waiting_deadline(self):
        files, _ = self.run_case(r'''
touch started
watchdog "$CASE_DIR" 600
''')
        self.assertEqual(files['state'], 'No\n')
        self.assertNotIn('1', files['writes'].splitlines())
        self.assertLess(int(files['clock']), 10)
        self.assertIn('restored', files)

    def test_expired_deadline_never_enables_sleep_override(self):
        files, _ = self.run_case('watchdog "$CASE_DIR" 0\n')
        self.assertNotIn('1', files.get('writes', '').splitlines())
        self.assertEqual(files['state'], 'No\n')

    def test_requested_stop_prevents_enable(self):
        files, _ = self.run_case('touch stop\nwatchdog "$CASE_DIR" 600\n')
        self.assertNotIn('1', files.get('writes', '').splitlines())
        self.assertEqual(files['state'], 'No\n')

    def test_normal_watchdog_enables_then_verifies_restore_at_deadline(self):
        files, _ = self.run_case('watchdog "$CASE_DIR" 3\n')
        self.assertEqual(files['writes'].splitlines(), ['1', '0'])
        self.assertEqual(files['state'], 'No\n')
        self.assertIn('restored', files)

    def test_ac_loss_restores_without_waiting_for_deadline(self):
        files, _ = self.run_case(r'''
power_snapshot() {
  local source='AC Power'
  [ "$(cat clock)" -lt 2 ] || source='Battery Power'
  printf "Now drawing from '%s'\n -InternalBattery-0 (id=123)\t100%%; charged; 0:00 remaining present: true\n" "$source"
}
watchdog "$CASE_DIR" 600
''')
        self.assertEqual(files['state'], 'No\n')
        self.assertLess(int(files['clock']), 10)

    def test_network_worker_has_independent_deadline(self):
        files, _ = self.run_case('network_worker "$CASE_DIR" 2\n')
        self.assertEqual(files['requests'].splitlines(), ['request', 'request'])

    def test_network_stops_on_stop_marker(self):
        files, _ = self.run_case('touch stop\nnetwork_worker "$CASE_DIR" 600\n')
        self.assertNotIn('requests', files)


    def test_launch_targets_system_even_when_caller_inherits_gui_domain(self):
        files, _ = self.run_case(r'''
launchctl_command() { printf '%s\n' "$@" > launch-args; }
launch_watchdog "$CASE_DIR/watchdog.plist"
''')
        args = files['launch-args'].splitlines()
        self.assertEqual(args[:2], ['bootstrap', 'system'])
        self.assertTrue(args[2].endswith('/watchdog.plist'))

    def test_stop_targets_only_named_system_service(self):
        files, _ = self.run_case(r'''
launchctl_command() { printf '%s\n' "$@" > stop-args; }
stop_watchdog local.agent-awake.probe.123
''')
        self.assertEqual(files['stop-args'].splitlines(),
                         ['bootout', 'system/local.agent-awake.probe.123'])

    def test_service_configuration_runs_as_root_and_restarts_only_on_failure(self):
        files, _ = self.run_case(r'''
write_watchdog_plist local.agent-awake.probe.123 /private/tmp/agent-awake-test.ABC123 123456 > job.plist
''')
        config = plistlib.loads(files['job.plist'].encode())
        self.assertEqual(config['UserName'], 'root')
        self.assertEqual(config['KeepAlive'], {'SuccessfulExit': False})
        self.assertTrue(config['RunAtLoad'])
        self.assertEqual(config['ProgramArguments'], ['/bin/bash', '--noprofile', '--norc',
            '/private/tmp/agent-awake-test.ABC123/watchdog.sh',
            '/private/tmp/agent-awake-test.ABC123', '123456', 'ac'])


    def test_battery_mode_runs_without_ac_and_restores_at_deadline(self):
        files, _ = self.run_case(r'''
power_snapshot() { printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t85%%; discharging; 5:00 remaining present: true\n"; }
watchdog "$CASE_DIR" 3 battery
''')
        self.assertEqual(files['writes'].splitlines(), ['1', '0'])
        self.assertEqual(files['state'], 'No\n')

    def test_battery_mode_does_not_start_at_or_below_twenty(self):
        for percent in (0, 19, 20):
            with self.subTest(percent=percent):
                files, _ = self.run_case('''
power_snapshot() { printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\tPERCENT%%; discharging; 0:30 remaining present: true\n"; }
watchdog "$CASE_DIR" 600 battery
'''.replace('PERCENT', str(percent)))
                self.assertNotIn('1', files.get('writes', '').splitlines())
                self.assertNotIn('ready', files)
                self.assertEqual(files['state'], 'No\n')

    def test_battery_mode_accepts_twenty_one(self):
        files, _ = self.run_case(r'''
power_snapshot() { printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t21%%; discharging; 0:30 remaining present: true\n"; }
watchdog "$CASE_DIR" 2 battery
''')
        self.assertEqual(files['writes'].splitlines(), ['1', '0'])

    def test_battery_drop_to_twenty_restores_early(self):
        files, _ = self.run_case(r'''
power_snapshot() {
  local percent=21
  [ "$(cat clock)" -lt 2 ] || percent=20
  printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t%s%%; discharging; 0:30 remaining present: true\n" "$percent"
}
watchdog "$CASE_DIR" 600 battery
''')
        self.assertEqual(files['writes'].splitlines(), ['1', '0'])
        self.assertLess(int(files['clock']), 10)

    def test_battery_sensor_failure_restores_early(self):
        files, _ = self.run_case(r'''
power_snapshot() {
  [ "$(cat clock)" -lt 2 ] || return 1
  printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t80%%; discharging; 5:00 remaining present: true\n"
}
watchdog "$CASE_DIR" 600 battery
''')
        self.assertEqual(files['writes'].splitlines(), ['1', '0'])
        self.assertLess(int(files['clock']), 10)

    def test_battery_test_stops_when_charger_connected(self):
        files, _ = self.run_case(r'''
power_snapshot() {
  local source='Battery Power'
  [ "$(cat clock)" -lt 2 ] || source='AC Power'
  printf "Now drawing from '%s'\n -InternalBattery-0 (id=123)\t80%%; discharging; 5:00 remaining present: true\n" "$source"
}
watchdog "$CASE_DIR" 600 battery
''')
        self.assertEqual(files['writes'].splitlines(), ['1', '0'])
        self.assertLess(int(files['clock']), 10)

    def test_battery_test_refuses_ac_power_at_start(self):
        files, _ = self.run_case('watchdog "$CASE_DIR" 600 battery\n')
        self.assertNotIn('1', files.get('writes', '').splitlines())

    def test_power_parser_rejects_missing_ambiguous_or_invalid_battery(self):
        snapshots = [
            "Now drawing from 'Battery Power'\n",
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123) 101%; discharging; present: true\n",
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123) unknown%; discharging; present: true\n",
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123) 85%; discharging; present: false\n",
            "Now drawing from 'UPS Power'\n -InternalBattery-0 (id=123) 85%; discharging; present: true\n",
        ]
        import shlex
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot):
                _, out = self.run_case("power_snapshot() { printf '%s' " + shlex.quote(snapshot) + "; }\n" +
                    'if power_allowed battery; then echo unsafe-accepted; else echo refused; fi\n')
                self.assertIn('refused', out)
                self.assertNotIn('unsafe-accepted', out)

    def test_plist_passes_battery_mode_to_independent_watchdog(self):
        files, _ = self.run_case(r'''
write_watchdog_plist local.agent-awake.probe.123 /private/tmp/agent-awake-test.ABC123 123456 battery > job.plist
''')
        config = plistlib.loads(files['job.plist'].encode())
        self.assertEqual(config['ProgramArguments'][-1], 'battery')

if __name__ == '__main__':
    unittest.main()

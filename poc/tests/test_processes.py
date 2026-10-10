"""Fault injection affects only fake power state and disposable child processes."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from test_lid_test import SCRIPT, HARNESS

class ProcessTests(unittest.TestCase):
    def wait_file(self, path, timeout=4):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if path.exists():
                return
            time.sleep(0.02)
        self.fail(f'Timed out waiting for {path.name}')

    def test_sigkill_parent_does_not_leave_network_worker_running(self):
        with tempfile.TemporaryDirectory() as d:
            code = HARNESS + r'''
now_seconds() { /bin/date +%s; }
pause() { /bin/sleep 0.05; }
DURATION=2
(network_worker "$CASE_DIR" "$(( $(now_seconds) + 2 ))"; touch done) &
touch parent-ready
wait
'''
            parent = subprocess.Popen(['/bin/bash', '-c', code],
                env={**os.environ, 'PROBE_SCRIPT': str(SCRIPT), 'CASE_DIR': d},
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.wait_file(Path(d) / 'parent-ready')
                self.wait_file(Path(d) / 'requests')
                parent.kill()
                parent.wait(timeout=2)
                self.wait_file(Path(d) / 'done')
                before = (Path(d) / 'requests').read_text()
                time.sleep(0.15)
                self.assertEqual((Path(d) / 'requests').read_text(), before)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=2)

    def test_sigkill_watchdog_restart_immediately_recovers(self):
        with tempfile.TemporaryDirectory() as d:
            env = {**os.environ, 'PROBE_SCRIPT': str(SCRIPT), 'CASE_DIR': d}
            code = HARNESS + r'''
now_seconds() { /bin/date +%s; }
pause() { /bin/sleep 0.02; }
watchdog "$CASE_DIR" "$(( $(now_seconds) + 600 ))"
'''
            first = subprocess.Popen(['/bin/bash', '-c', code], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.wait_file(Path(d) / 'ready')
                self.assertEqual((Path(d) / 'state').read_text(), 'Yes\n')
                first.kill()
                first.wait(timeout=2)
                restarted = subprocess.run(['/bin/bash', '-c', code], env=env,
                    capture_output=True, text=True, timeout=3)
                self.assertEqual(restarted.returncode, 0, restarted.stderr)
                self.assertEqual((Path(d) / 'state').read_text(), 'No\n')
                self.assertEqual((Path(d) / 'writes').read_text().splitlines(), ['1', '0'])
                self.assertTrue((Path(d) / 'restored').exists())
            finally:
                if first.poll() is None:
                    first.kill()
                    first.wait(timeout=2)

    def test_network_elapsed_limit_survives_clock_moving_backwards(self):
        with tempfile.TemporaryDirectory() as d:
            code = HARNESS + r'''
now_seconds() { echo 0; }
pause() { /bin/sleep 0.05; }
DURATION=1
network_worker "$CASE_DIR" 600
echo finished
'''
            result = subprocess.run(['/bin/bash', '-c', code],
                env={**os.environ, 'PROBE_SCRIPT': str(SCRIPT), 'CASE_DIR': d},
                capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('finished', result.stdout)

    def test_completed_watchdog_restart_does_not_restore_over_a_new_session(self):
        with tempfile.TemporaryDirectory() as d:
            code = HARNESS + r'''
touch started restored
LOCK_DIR="$CASE_DIR/lock"
mkdir "$LOCK_DIR"
echo different-session > "$LOCK_DIR/session"
watchdog "$CASE_DIR" 600
'''
            result = subprocess.run(['/bin/bash', '-c', code],
                env={**os.environ, 'PROBE_SCRIPT': str(SCRIPT), 'CASE_DIR': d},
                capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((Path(d) / 'writes').exists(), 'Old completed job changed power settings again')
            self.assertEqual((Path(d) / 'state').read_text(), 'Yes\n')
            self.assertEqual((Path(d) / 'lock/session').read_text(), 'different-session\n')

if __name__ == '__main__':
    unittest.main()

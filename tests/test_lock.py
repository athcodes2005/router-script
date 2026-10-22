"""F39: one maintenance-lock helper. Owners are identified, never aged out by the clock."""
import os
import re
import signal
import subprocess
import time
import unittest

from sandbox import Sandbox, SHELL

BLOCK = ': > "$SIM_STATE/blocked"\nexec /bin/sleep 30\n'
# Takes the lock without waiting, records the result, holds it for a second.
CONTENDER = r'''DIR="$(cd "$(dirname "$0")" && pwd)"
log() { :; }
. "$DIR/lock.sh"
if acquire_maintenance_lock 0; then
    : > "$SIM_STATE/won.$$"
    /bin/sleep 1
    release_maintenance_lock
fi
'''


def dead_pid():
    process = subprocess.Popen(['true'])
    process.wait()
    return process.pid


def proc_stat(pid, start):
    """A /proc/PID/stat line whose field 22 (start time) is `start`."""
    return '%d (sleep) S %s %d %s\n' % (pid, ' '.join(['0'] * 18), start, ' '.join(['0'] * 30))


class LockTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.lock = self.box.proj / '.ensure_network.lock'

    def sleeper(self):
        process = subprocess.Popen(['sleep', '300'])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        return process.pid

    def hold(self, owner, age=0):
        """A lock someone else took `age` seconds ago; `owner` is the owner file, if any."""
        self.lock.mkdir()
        if owner is not None:
            (self.lock / 'owner').write_text(owner + '\n')
        stamp = time.time() - age
        os.utime(self.lock, (stamp, stamp))

    def fake_proc(self, name, text):
        path = self.box.sysroot / 'proc' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def tick(self):
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.box.log('ensure')

    def test_a_live_owner_keeps_the_lock_however_old_it_looks(self):
        pid = self.sleeper()
        self.fake_proc('uptime', '5000.42 9000.00\n')
        self.hold('%d 0 4900 game_mode.sh' % pid, age=3600)
        log = self.tick()
        self.assertIn('Skipped: game_mode.sh (PID %d) holds the maintenance lock.' % pid, log)
        self.assertNotIn('Starting health check', log)
        self.assertTrue((self.lock / 'owner').exists())

    def test_a_dead_owner_is_taken_over_at_once(self):
        pid = dead_pid()
        self.hold('%d 0 0 rotate_tunnel_ip.sh' % pid)
        log = self.tick()
        self.assertIn('WARNING: taking over the maintenance lock: its owner, '
                      'rotate_tunnel_ip.sh (PID %d), is gone.' % pid, log)
        self.assertIn('Health check passed.', log)
        self.assertFalse(self.lock.exists())

    def test_the_recorded_start_time_tells_a_reused_pid_from_the_owner(self):
        pid = self.sleeper()
        self.fake_proc('%d/stat' % pid, proc_stat(pid, 777))
        self.hold('%d 777 0 game_mode.sh' % pid)
        self.assertIn('Skipped: game_mode.sh (PID %d) holds the maintenance lock.' % pid, self.tick())
        (self.lock / 'owner').write_text('%d 123 0 game_mode.sh\n' % pid)
        log = self.tick()
        self.assertIn('is gone; the PID now belongs to another process.', log)
        self.assertIn('Health check passed.', log)

    def test_an_owner_that_hangs_is_taken_over_after_the_hold_limit(self):
        pid = self.sleeper()
        self.fake_proc('uptime', '5000.42 9000.00\n')
        self.hold('%d 0 4300 rotate_tunnel_ip.sh' % pid)
        log = self.tick()
        self.assertIn('rotate_tunnel_ip.sh (PID %d) has held it for 700s.' % pid, log)
        self.assertIn('Health check passed.', log)

    # F21: after a reboot the clock can read months behind until NTP syncs, so
    # a lock left from before the reboot looked newer than now and never aged.
    def test_an_ownerless_lock_dated_in_the_future_is_taken_over(self):
        self.hold(None, age=-86400)
        log = self.tick()
        self.assertRegex(log, r'it records no owner and is dated 86(39\d|400)s in the future\.')
        self.assertIn('Health check passed.', log)

    def test_an_old_ownerless_lock_is_taken_over(self):
        self.hold(None, age=600)
        log = self.tick()
        self.assertRegex(log, r'it records no owner and is 60\ds old\.')
        self.assertIn('Health check passed.', log)

    def test_a_young_ownerless_lock_is_respected(self):
        self.hold(None, age=5)
        log = self.tick()
        self.assertIn('Skipped: an unrecorded owner holds the maintenance lock.', log)
        self.assertNotIn('Starting health check', log)

    def test_the_health_check_records_itself_and_releases_the_lock(self):
        self.tick()
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.lock.with_name('.ensure_network.lock.takeover').exists())

    def test_only_one_of_two_contenders_takes_over_a_stale_lock(self):
        (self.box.proj / 'contender.sh').write_text(CONTENDER)
        for _ in range(5):
            for old in self.box.state.glob('won.*'):
                old.unlink()
            self.hold('%d 0 0 rotate_tunnel_ip.sh' % dead_pid())
            contenders = [self.box.start('contender.sh') for _ in range(2)]
            for process in contenders:
                process.communicate(timeout=60)
            self.assertEqual(len(list(self.box.state.glob('won.*'))), 1)
            self.assertFalse(self.lock.exists())

    def test_game_mode_owns_the_lock_while_it_works(self):
        self.box.flag('curl_blocks')  # game mode's closing status probe
        process = self.box.start('game_mode.sh', 'on')
        self.addCleanup(lambda: process.poll() is None and os.killpg(process.pid, signal.SIGKILL))
        deadline = time.time() + 30
        while not (self.box.state / 'blocked').exists():
            self.assertLess(time.time(), deadline, 'game mode never reached the blocking step')
            time.sleep(0.1)
        owner = (self.lock / 'owner').read_text().split()
        self.assertEqual(owner[0], str(process.pid))
        self.assertEqual(owner[3], 'game_mode.sh')
        self.assertIn('Skipped: game_mode.sh (PID %d) holds the maintenance lock.' % process.pid, self.tick())
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=60)
        self.assertFalse(self.lock.exists())


if __name__ == '__main__':
    unittest.main()

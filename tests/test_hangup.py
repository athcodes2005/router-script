"""F19: an SSH drop sends SIGHUP to the foreground job and takes its terminal away."""
import os
import signal
import time
import unittest

from sandbox import Sandbox, SHELL

ORIGINAL = '{"dummy": "original-registration"}\n'
BLOCK = ': > "$SIM_STATE/blocked"\nexec /bin/sleep 30\n'


class HangupTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def hang_up(self, process):
        """Wait until the job blocks, close its output and send SIGHUP to the whole job."""
        def kill():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.addCleanup(kill)
        deadline = time.time() + 30
        while not (self.box.state / 'blocked').exists():
            self.assertLess(time.time(), deadline, 'the job never reached the blocking step')
            self.assertIsNone(process.poll(), 'the job exited before blocking')
            time.sleep(0.1)
        # Writes to a dropped terminal fail; a closed pipe makes them fail here.
        process.stdout.close()
        process.stderr.close()
        os.killpg(process.pid, signal.SIGHUP)
        return process.wait(timeout=60)

    def test_rotation_restores_the_registration_and_releases_the_lock(self):
        proj = self.box.proj
        (proj / 'config.json').write_text(ORIGINAL)  # a dummy; the real one never enters the sandbox
        (proj / 'stop_tunnel.sh').write_text('exit 0\n')
        # Register, then block. The restart during cleanup must not block again.
        (proj / 'tunnel.sh').write_text(
            '[ -f "$(dirname "$0")/config.json" ] || echo new > "$(dirname "$0")/config.json"\n'
            '[ ! -f "$SIM_STATE/blocked" ] || exit 0\n' + BLOCK)
        self.assertEqual(self.hang_up(self.box.start('rotate_tunnel_ip.sh')), 129)
        self.assertFalse((proj / '.ensure_network.lock').exists())
        self.assertEqual((proj / 'config.json').read_text(), ORIGINAL)
        self.assertFalse((proj / 'config.json.previous').exists())

    def test_game_mode_releases_the_lock(self):
        (self.box.sysroot / 'etc/init.d/dnsmasq').write_text('#!%s\n%s' % (SHELL, BLOCK))
        self.assertEqual(self.hang_up(self.box.start('game_mode.sh', 'on')), 129)
        self.assertFalse((self.box.proj / '.ensure_network.lock').exists())


if __name__ == '__main__':
    unittest.main()

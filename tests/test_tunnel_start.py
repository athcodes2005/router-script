"""tunnel.sh's start path, taken through its "reuse the running client" branch."""
import subprocess
import unittest

from sandbox import Sandbox, SHELL

STALE = '203.0.113.9/32'


class TunnelStartTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        # A dummy client that advertises both options, plus a live PID for
        # `pidof usque-rs`; the binaries and config.json never enter the sandbox.
        client = self.box.proj / 'usque-rs'
        client.write_text('#!%s\necho "--congestion-control --ready-file"\n' % SHELL)
        client.chmod(0o755)
        (self.box.proj / 'config.json').write_text('{"dummy": "registration"}\n')
        sleeper = subprocess.Popen(['sleep', '300'])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        (self.box.state / 'usque_pid').write_text('%d\n' % sleeper.pid)
        self.public = self.box.tmp / 'router-script-direct-public-host-routes'
        self.campus = self.box.tmp / 'router-script-campus-host-routes'

    def start(self):
        result = self.box.run('tunnel.sh')
        return result.returncode, self.box.log('tunnel')

    def test_reused_client_start_completes(self):
        status, log = self.start()
        self.assertEqual(status, 0, log)
        self.assertIn('[SUCCESS] Full tunnel active', log)
        self.assertEqual(self.box.count('ip route add default dev tun0 metric 5'), 1)


if __name__ == '__main__':
    unittest.main()

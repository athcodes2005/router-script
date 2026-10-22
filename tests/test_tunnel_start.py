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

    # F32: deleting every host route before resolving put those hosts on WARP
    # (tun0 is the live default on this path), and a failed lookup lost its route.
    def test_start_removes_no_host_routes(self):
        self.public.write_text(self.public.read_text() + STALE + '\n')
        status, log = self.start()
        self.assertEqual(status, 0, log)
        self.assertFalse([c for c in self.box.calls() if c.startswith('ip route del') and '/32' in c])
        listed = self.public.read_text().splitlines()
        self.assertIn('198.51.100.10/32', listed)
        self.assertIn(STALE, listed)  # left for the health check to judge

    def test_failed_lookups_keep_existing_host_routes(self):
        before = self.campus.read_text()
        self.assertIn('198.51.100.10/32', before)
        self.box.flag('dns_fail')
        status, log = self.start()
        self.assertEqual(status, 0, log)
        self.assertEqual(self.campus.read_text(), before)
        self.assertEqual(self.box.count('ip route del 198.51.100.10/32'), 0)

    def test_health_check_still_removes_stale_routes_after_a_start(self):
        self.public.write_text(self.public.read_text() + STALE + '\n')
        self.start()
        self.box.run('ensure_network.sh')
        self.assertEqual(self.box.count('ip route del ' + STALE + ' via 10.1.40.250 dev eth0 metric 1'), 1)

    # F33: the first default that is not tun0 can belong to another uplink.
    def test_gateway_comes_from_the_wan_interface(self):
        self.box.flag('extra_default')
        status, log = self.start()
        self.assertEqual(status, 0, log)
        self.assertFalse([c for c in self.box.calls() if 'via 192.168.100.1' in c])
        self.assertIn('ip route replace 10.0.0.0/8 via 10.1.40.250 dev eth0 metric 1', self.box.calls())

    # F34: under set -e one failed optional host route ended the whole start.
    def test_failed_host_route_does_not_abort_the_start(self):
        self.box.flag('host_route_fail')
        status, log = self.start()
        self.assertEqual(status, 0, log)
        self.assertIn('[WARNING] Could not install the host route 198.51.100.10/32', log)
        self.assertIn('[SUCCESS] Full tunnel active', log)
        self.assertEqual(self.box.count('ip route add default dev tun0 metric 5'), 1)


if __name__ == '__main__':
    unittest.main()

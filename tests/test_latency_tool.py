"""measure_load_latency.sh: WARP round trips idle and under load, without reconfiguring."""
import unittest

from sandbox import Sandbox


class LatencyToolTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.lock = self.box.proj / '.ensure_network.lock'

    def measure(self, *args):
        return self.box.run('measure_load_latency.sh', *args)

    def test_three_phases_are_measured_through_the_tunnel(self):
        result = self.measure('8')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.box.log('latency')
        self.assertIn('client 456 (no --tun-backpressure)', log)
        self.assertIn('Latency idle:     min/median/max = 21/21/21 ms (8 samples, 0 failed).', log)
        self.assertIn('Latency upload:   min/median/max = 21/21/21 ms (4 samples, 0 failed); 32.0 Mbit/s.', log)
        self.assertIn('Latency download: min/median/max = 21/21/21 ms (4 samples, 0 failed); 100.0 Mbit/s.', log)
        curls = [c for c in self.box.calls() if c.startswith('curl ')]
        self.assertTrue(all('--interface tun0' in c for c in curls))
        self.assertEqual(len([c for c in curls if ' -T - ' in c and '--max-time 8' in c]), 1)
        self.assertFalse(self.lock.exists())
        # Measuring changes nothing.
        for prefix in ('ip route', 'ip rule', 'iptables -I', 'iptables -D', 'uci set', 'killall'):
            self.assertEqual(self.box.count(prefix), 0, prefix)

    def test_failed_round_trips_are_counted(self):
        self.box.flag('rtt_fail')
        self.measure('8')
        self.assertIn('Latency idle:     no replies (8 failed).', self.box.log('latency'))

    def test_nothing_is_measured_without_warp(self):
        self.box.flag('warp_down')
        self.assertEqual(self.measure('8').returncode, 1)
        self.assertIn('WARP is not running; nothing to measure.', self.box.log('latency'))

    def test_a_busy_lock_is_waited_for_then_reported(self):
        self.lock.mkdir()
        (self.lock / 'owner').write_text('%d 0 0 game_mode.sh\n' % self.sleeper())
        result = self.measure('8')
        self.assertEqual(result.returncode, 1)
        self.assertIn('holds the maintenance lock; try again later.', self.box.log('latency'))
        self.assertTrue((self.lock / 'owner').exists())

    def sleeper(self):
        import subprocess
        process = subprocess.Popen(['sleep', '300'])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        return process.pid


if __name__ == '__main__':
    unittest.main()

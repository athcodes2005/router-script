"""measure_load_latency.sh: WARP round trips idle and under load, without reconfiguring."""
import re
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
        self.assertIn('client 456 (no --tun-backpressure or --upload-codel).', log)
        self.assertIn('Latency idle:     min/median/max = 21/21/21 ms (8 samples, 0 failed).', log)
        self.assertIn('Latency upload:   min/median/max = 21/21/21 ms (4 samples, 0 failed); 32.0 Mbit/s.', log)
        self.assertRegex(log, r'Latency download: min/median/max = 21/21/21 ms \(4 samples, 0 failed\); '
                              r'\d+\.\d Mbit/s \(\d+ transfers\)\.')
        curls = [c for c in self.box.calls() if c.startswith('curl ')]
        self.assertTrue(all('--interface tun0' in c for c in curls))
        self.assertEqual(len([c for c in curls if ' -T - ' in c and '--max-time 8' in c]), 1)
        self.assertFalse(self.lock.exists())
        # Measuring changes nothing.
        for prefix in ('ip route', 'ip rule', 'iptables -I', 'iptables -D', 'uci set', 'killall'):
            self.assertEqual(self.box.count(prefix), 0, prefix)

    def download_transfers(self):
        return [c for c in self.box.calls() if c.startswith('curl ') and '/__down' in c]

    # The speed test refuses 100 MB and more, and a fast link finishes the 75 MB
    # it serves within seconds, so a single request left most of the phase idle.
    def test_downloads_repeat_until_the_phase_ends(self):
        result = self.measure('8')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        transfers = self.download_transfers()
        self.assertGreaterEqual(len(transfers), 3)
        self.assertTrue(all('bytes=75000000' in c for c in transfers))
        # Each request gets only the time left in the phase.
        limits = [int(re.search(r'--max-time (\d+)', c).group(1)) for c in transfers]
        self.assertLessEqual(limits[0], 8)
        self.assertEqual(limits, sorted(limits, reverse=True))
        match = re.search(r'Latency download: .*; \d+\.\d Mbit/s \((\d+) transfers\)\.', self.box.log('latency'))
        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1)), len(transfers))

    def test_a_refused_download_is_reported_not_retried(self):
        self.box.flag('download_refused')
        self.assertEqual(self.measure('8').returncode, 0)
        self.assertEqual(len(self.download_transfers()), 1)
        self.assertIn('; no download (HTTP 403).', self.box.log('latency'))

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

    # F10: each run names the client's upload-queue options, so that runs with
    # and without them can be told apart in logs/latency.log.
    def test_each_run_names_the_clients_upload_queue_options(self):
        proc = self.box.sysroot / 'proc' / '456'
        proc.mkdir(parents=True)
        (proc / 'cmdline').write_bytes(b'\0'.join([
            b'/root/router-script/usque-rs', b'--config', b'config.json', b'nativetun',
            b'--interface-name', b'tun0', b'--syslog', b'--tun-backpressure', b'64',
            b'--upload-codel', b'20', b'']))
        self.assertEqual(self.measure('8').returncode, 0)
        self.assertIn('client 456 (--tun-backpressure 64, --upload-codel 20).', self.box.log('latency'))

    def sleeper(self):
        import subprocess
        process = subprocess.Popen(['sleep', '300'])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        return process.pid


if __name__ == '__main__':
    unittest.main()

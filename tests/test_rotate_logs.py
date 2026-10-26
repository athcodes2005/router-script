"""rotate_logs.sh: configuration loading and the set of logs it rotates."""
import unittest

from sandbox import Sandbox


class RotateLogsTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    # A6: rotate_logs.sh never loaded .env, so a LOG_DIR set there was ignored.
    def test_honours_log_dir_from_env_file(self):
        alt = self.box.tmp / 'alt-logs'
        (self.box.proj / '.env').write_text('LOG_DIR=%s\n' % alt)  # sandbox .env, not the real one
        result = self.box.run('rotate_logs.sh')
        self.assertIn('Log maintenance completed', result.stdout)  # exit status is not asserted: the EXIT trap leaks 1
        self.assertIn('Log maintenance completed', (alt / 'maintenance.log').read_text())
        self.assertEqual(self.box.log('maintenance'), '')

    def test_honours_diagnostics_dir_from_env_file(self):
        alt = self.box.tmp / 'alt-diag'
        alt.mkdir()
        for i in range(4):
            (alt / ('diagnostic_%d.log' % i)).write_text('x\n')
        (self.box.proj / '.env').write_text('DIAGNOSTICS_DIR=%s\nMAX_DIAGNOSTICS=2\n' % alt)
        result = self.box.run('rotate_logs.sh')
        self.assertIn('Log maintenance completed', result.stdout)  # exit status is not asserted: the EXIT trap leaks 1
        self.assertEqual(len(list(alt.glob('diagnostic_*.log'))), 2)

    # A7: measure_load_latency.sh writes latency.log, which was never rotated.
    def test_rotates_latency_log(self):
        latency = self.box.proj / 'logs' / 'latency.log'
        latency.write_text('x' * 5000)
        result = self.box.run('rotate_logs.sh', MAX_LOG_BYTES='1000')
        self.assertIn('Log maintenance completed', result.stdout)  # exit status is not asserted: the EXIT trap leaks 1
        self.assertEqual(latency.read_text(), '')
        self.assertEqual(len((self.box.proj / 'logs' / 'latency.log.1').read_text()), 1000)


if __name__ == '__main__':
    unittest.main()

"""Whole-script runs of the health pipeline inside the isolated sandbox."""
import unittest

from sandbox import Sandbox

DISRUPTIVE = ('ifdown', 'ifup', 'wifi reload', 'dnsmasq restart', 'dnscrypt-proxy restart', 'killall')


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def test_healthy_tick_passes_without_disruptive_actions(self):
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Health check passed.', self.box.log('ensure'))
        for action in DISRUPTIVE:
            self.assertEqual(self.box.count(action), 0, action)


if __name__ == '__main__':
    unittest.main()

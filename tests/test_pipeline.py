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

    def tick(self, **env):
        return self.box.run('ensure_network.sh', **env)

    # F02: a stuck Wi-Fi or DNS stage must not block WAN, portal and WARP recovery.
    def test_wifi_config_failure_does_not_block_tunnel_recovery(self):
        self.box.flag('wifi_drift')
        self.box.flag('warp_down')
        self.tick()
        log = self.box.log('ensure')
        self.assertIn('Wi-Fi stability configuration drift detected', log)
        self.assertIn('Tunnel health check failed: process missing. Restarting tunnel.', log)

    def test_persistent_radio_failure_is_reloaded_once_per_cooldown(self):
        self.box.flag('wifi_down')
        self.tick()
        self.tick()
        self.assertEqual(self.box.count('wifi reload'), 1)
        self.assertIn('Wi-Fi remains degraded; repair cooldown is active.', self.box.log('ensure'))

    def test_dns_config_drift_does_not_block_portal_recovery(self):
        self.box.flag('dns_drift')
        self.box.flag('direct_down')
        self.tick()
        log = self.box.log('ensure')
        self.assertIn('DNS configuration drift detected', log)
        self.assertIn('IPv4 internet check failed twice. Running login.sh.', log)

    def test_persistent_dns_config_repair_is_rate_limited(self):
        self.box.flag('dns_drift')
        self.tick()
        self.tick()
        self.assertEqual(self.box.count('dnsmasq restart'), 1)
        self.assertIn('Health check passed.', self.box.log('ensure'))

    def test_dead_resolver_still_stops_before_probe_driven_recovery(self):
        self.box.flag('dnsmasq_down')
        self.box.flag('direct_down')
        self.assertEqual(self.tick().returncode, 1)
        self.assertEqual(self.tick().returncode, 1)
        self.assertEqual(self.box.log('login'), '')
        self.assertEqual(self.box.count('dnsmasq restart'), 1)


if __name__ == '__main__':
    unittest.main()

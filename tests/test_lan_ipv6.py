"""F47: on GL.iNet 4.11.0 every ifup turns IPv6 off on every interface.

While GL.iNet's own IPv6 switch (glipv6.globals.enabled) is off, its
/etc/hotplug.d/iface/99-disable_ipv6 sets disable_ipv6=1 on every interface at
each ifup, which drops br-lan's address. The sandbox's glipv6_hook flag models
that hook. A repair that runs `ifup lan` and stops there undoes itself.
"""
import unittest

from sandbox import Sandbox

LAN_ADDRESS_ADD = 'ip -6 addr add fd63:3b28:d1ea::1/64 dev br-lan'


class LanIpv6Tests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.box.flag('glipv6_hook')

    def tick(self):
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.box.log('ensure')

    def lan_has_address(self):
        return not (self.box.state / 'lan_ipv6_missing').exists()

    def test_an_address_lost_to_the_hook_is_restored_without_reloading_the_lan(self):
        # What any ifup leaves behind: IPv6 off on br-lan, and no address.
        self.box.flag('lan_ipv6_disabled')
        self.box.flag('lan_ipv6_missing')
        log = self.tick()
        self.assertIn('LAN IPv6 runtime address restored in place (no LAN reload).', log)
        self.assertNotIn('LAN IPv6 configuration drift detected', log)
        self.assertTrue(self.lan_has_address())
        self.assertEqual(self.box.count('ifup'), 0)
        self.assertEqual(self.box.count('dnsmasq restart'), 0)
        # Fresh router advertisements announce the restored gateway.
        self.assertEqual(self.box.count('odhcpd restart'), 1)
        self.assertIn('Health check passed.', log)

    def test_the_full_repair_puts_the_address_back_after_its_own_ifup(self):
        self.box.flag('lan_ra_default_drift')  # drift that only configure_lan_ipv6.sh repairs
        log = self.tick()
        self.assertIn('LAN IPv6 configuration drift detected', log)
        self.assertIn('LAN IPv6 configuration recovered.', log)
        self.assertTrue(self.lan_has_address())
        calls = self.box.calls()
        added = calls.index(LAN_ADDRESS_ADD)
        self.assertLess(calls.index('ifup lan'), added)
        # odhcpd starts only once the address exists, so its RAs carry it.
        self.assertLess(added, max(i for i, call in enumerate(calls) if call == 'odhcpd restart'))

    def test_without_a_configured_address_the_full_repair_runs(self):
        # Nothing to restore in place: configure_lan_ipv6.sh sets ip6addr first.
        self.box.flag('lan_ip6addr_unset')
        self.box.flag('lan_ipv6_missing')
        log = self.tick()
        self.assertNotIn('restored in place', log)
        self.assertIn('LAN IPv6 configuration recovered.', log)
        self.assertEqual(self.box.count('ifup lan'), 1)
        self.assertTrue(self.lan_has_address())


if __name__ == '__main__':
    unittest.main()

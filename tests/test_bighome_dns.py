"""bighome.iitb.ac.in is internal-only: it must be forwarded to campus DNS and its absence is drift."""
import unittest

from sandbox import Sandbox


class BighomeDnsTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def test_configure_dns_forwards_bighome_to_campus_dns(self):
        result = self.box.run('configure_dns.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('uci add_list dhcp.@dnsmasq[0].server=/bighome.iitb.ac.in/10.200.1.11',
                      self.box.calls())

    def test_router_missing_bighome_entry_is_dns_drift(self):
        self.box.flag('dns_drift_bighome')
        self.box.run('ensure_network.sh')
        self.assertIn('DNS configuration drift detected', self.box.log('ensure'))

    def test_router_with_bighome_entry_is_not_drift(self):
        self.box.run('ensure_network.sh')
        self.assertNotIn('DNS configuration drift detected', self.box.log('ensure'))


if __name__ == '__main__':
    unittest.main()

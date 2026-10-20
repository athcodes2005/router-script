import importlib.util
import ipaddress
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('google_ranges', ROOT / 'tools/update_google_ranges.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def feed(*ranges):
    return {'prefixes': [{'ipv6Prefix' if ':' in item else 'ipv4Prefix': item} for item in ranges]}

class GoogleRangesTests(unittest.TestCase):
    def test_subtract_customer_networks_both_families(self):
        result = module.service_ranges(feed('8.8.8.0/24', '2001:4860::/32'),
                                       feed('8.8.8.0/25', '2001:4860::/33'))
        self.assertEqual([str(n) for n in result], ['8.8.8.128/25', '2001:4860:8000::/33'])

    def test_larger_exclusion_and_unrelated_cloud_range(self):
        result = module.service_ranges(feed('8.8.8.0/24', '9.9.9.0/24'),
                                       feed('8.8.0.0/16', '1.1.1.0/24'))
        self.assertEqual([str(n) for n in result], ['9.9.9.0/24'])

    def test_reject_empty_private_and_default(self):
        for ranges in [(), ('10.0.0.0/8',), ('0.0.0.0/0',), ('::/0',)]:
            with self.subTest(ranges=ranges), self.assertRaises(ValueError):
                module.service_ranges(feed(*ranges), feed())

    def test_shipped_ranges_include_google_dns(self):
        networks = [ipaddress.ip_network(line) for line in (ROOT / 'google_service_ranges.txt').read_text().splitlines() if line and not line.startswith('#')]
        for address in ['8.8.8.8', '2001:4860:4860::8888']:
            self.assertTrue(any(ipaddress.ip_address(address) in n for n in networks))
        self.assertTrue(all(n.is_global and n.prefixlen > 0 for n in networks))

if __name__ == '__main__':
    unittest.main()

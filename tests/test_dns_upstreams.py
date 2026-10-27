"""dnsproxy: Cloudflare in parallel as primary, Quad9 only as fallback; bigger caches; drift repair."""
import re
import unittest

from sandbox import Sandbox

OLD_YAML = ('---\nupstream:\n  - "tls://1.1.1.1:853"\n  - "tls://9.9.9.9:853"\n'
            '  - "https://dns.quad9.net/dns-query"\nlisten-ports:\n  - 5453\ntimeout: \'5s\'\n')


def section(text, key):
    """Lines of the top-level YAML list `key`."""
    m = re.search(r'^%s:\n((?:[ \t]+.*\n)*)' % re.escape(key), text, re.M)
    return m.group(1) if m else ''


class DnsUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.yaml = self.box.sysroot / 'etc/dnsproxy/dnsproxy.yaml'

    def configure(self, **env):
        result = self.box.run('configure_dns.sh', **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def drifted(self):
        self.box.run('ensure_network.sh')
        return 'DNS configuration drift detected' in self.box.log('ensure')

    def test_generated_yaml_has_cloudflare_upstream_and_quad9_fallback(self):
        self.configure()
        text = self.yaml.read_text()
        up, fb = section(text, 'upstream'), section(text, 'fallback')
        for u in ('tls://1.1.1.1:853', 'tls://1.0.0.1:853', 'https://cloudflare-dns.com/dns-query'):
            self.assertIn(u, up)
        self.assertNotRegex(up, r'9\.9\.9\.9|quad9')
        self.assertIn('tls://9.9.9.9:853', fb)
        self.assertIn('https://dns.quad9.net/dns-query', fb)
        self.assertNotIn('cloudflare', fb)

    def test_generated_yaml_cache_and_timeout_keys(self):
        self.configure()
        text = self.yaml.read_text()
        self.assertIn("timeout: '2s'", text)
        self.assertIn('cache: true', text)
        self.assertIn('cache-size: 4194304', text)
        self.assertIn('cache-optimistic: true', text)
        self.assertIn('- 5453', text)

    def test_configure_dns_sets_dnsmasq_cachesize(self):
        self.configure()
        self.assertIn('uci set dhcp.@dnsmasq[0].cachesize=4000', self.box.calls())

    def test_configure_dns_cachesize_follows_env_override(self):
        self.configure(DNS_CACHE_SIZE='9000')
        self.assertIn('uci set dhcp.@dnsmasq[0].cachesize=9000', self.box.calls())

    def test_new_config_is_not_drift(self):
        self.assertFalse(self.drifted())

    def test_old_yaml_with_quad9_upstream_is_drift(self):
        self.yaml.write_text(OLD_YAML)
        self.assertTrue(self.drifted())

    def test_yaml_with_quad9_under_upstream_and_fallback_is_drift(self):
        text = self.yaml.read_text()
        self.yaml.write_text(text.replace('upstream:\n', 'upstream:\n  - "tls://9.9.9.9:853"\n', 1))
        self.assertTrue(self.drifted())

    def test_yaml_without_optimistic_cache_is_drift(self):
        self.yaml.write_text(self.yaml.read_text().replace('cache-optimistic: true', ''))
        self.assertTrue(self.drifted())

    def test_wrong_cachesize_is_drift(self):
        self.box.flag('cachesize_small')
        self.assertTrue(self.drifted())

    def test_missing_cachesize_is_drift(self):
        self.box.flag('cachesize_unset')
        self.assertTrue(self.drifted())


if __name__ == '__main__':
    unittest.main()

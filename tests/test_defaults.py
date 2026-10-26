"""A1: a default that several scripts share lives only in defaults.sh."""
from pathlib import Path
import re
import subprocess
import unittest

from sandbox import SHELL

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = re.compile(r'^\s*([A-Z0-9_]+)="\$\{\1:-', re.M)
SOURCES_DEFAULTS = re.compile(r'^\. "\$(SCRIPT_)?DIR/defaults\.sh"$', re.M)
# Every copy had exactly these values when they moved into defaults.sh.
EXPECTED = {
    'WAN_IF': 'eth0', 'WAN_UCI_IFACE': 'wan', 'LAN_IF': 'br-lan', 'LAN_SUBNET': '192.168.8.0/24',
    'TUN_IF': 'tun0', 'TUN_IPV4_MSS': '1240', 'TUN_IPV6_MSS': '1220',
    'LAN_IP6IFACEID': '::1', 'LAN_RA_DEFAULT': '2',
    'CAMPUS_DNS_IP': '10.200.1.11', 'CAMPUS_NETS': '10.0.0.0/8 103.21.124.0/22',
    'CAMPUS_DOMAINS': 'internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in '
                      'portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in',
    'CAMPUS_DIRECT_DOMAINS': 'www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in '
                             'mulyankan.cse.iitb.ac.in webmail.iitb.ac.in',
    'PORTAL_IP': '10.201.250.201', 'SSO_IP': '10.200.1.100',
    'DNSCRYPT_TOML': '/etc/dnscrypt-proxy2/dnscrypt-proxy.toml',
    'DNSPROXY_YAML': '/etc/dnsproxy/dnsproxy.yaml',
    'DNS_SERVERS': '127.0.0.1#5453 8.8.8.8 8.8.4.4 10.200.1.11',
    'DIRECT_PUBLIC_DOMAINS': 'api3.blinkit.com jumbo.blinkit.com api2.grofers.com o1069899.ingest.us.sentry.io '
                             'gemini.google.com game.clashroyaleapp.com id.supercell.com init.mkt.supercell.com '
                             'o315582.ingest.sentry.io clashroyale.com www.clashroyale.com',
    'BLINKIT_IPV4_DOMAINS': 'api3.blinkit.com jumbo.blinkit.com api2.grofers.com',
    'BLINKIT_HOSTS_DIR': '/etc/router-script/blinkit-hosts', 'DNSMASQ_PID_DIR': '/var/run',
    'CAMPUS_ROUTES_FILE': '/tmp/router-script-campus-host-routes',
    'DIRECT_PUBLIC_ROUTES_FILE': '/tmp/router-script-direct-public-host-routes',
    'GAME_SESSION_ROUTES_FILE': '/tmp/router-script-game-session-host-routes',
    'GAME_SESSION_PORTS': '9339', 'GAME_POLICY_TABLE': '101', 'GAME_POLICY_PRIORITY': '700',
    'GAME_POLICY_MARK': '0x40000', 'GAME_POLICY_MASK': '0xf0000',
    'GAME_MODE_MARKER': '/tmp/router-script-game-mode',
    'WARP_ENDPOINTS': '162.159.198.1 162.159.192.1', 'WARP_READY_FILE': '/tmp/router-script-warp-ready',
    'WARP_CLIENT_TABLE': '100',
    'USQUE_REPO': 'athcodes2005/usque-rs-openwrt', 'USQUE_RELEASE_TAG': 'latest',
    'USQUE_ASSET_NAME': 'usque-rs-aarch64-linux-musl.tar.gz',
    'INTERNET_PROBE_URLS': 'https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204',
    'INTERACTIVE_LOGIN_MARKER': '/tmp/router-script-interactive-login-required',
    'WIFI_COUNTRY': 'IN', 'WIFI_2G_DEVICE': 'mt798111', 'WIFI_5G_DEVICE': 'mt798112',
    'WIFI_2G_HTMODE': 'HE20', 'WIFI_5G_HTMODE': 'HE80',
    'MAX_DIAGNOSTICS': '24',
}


def deployed_scripts():
    files = re.search(r'^FILES="([^"]*)"', (ROOT / 'sync_to_router.sh').read_text(), re.M).group(1).split()
    return [ROOT / name for name in files if name.endswith('.sh')]


def resolve(names, **env):
    """The values defaults.sh gives `names` in an otherwise empty environment."""
    script = '. ./defaults.sh\n' + ''.join('printf "%%s\\n" "$%s"\n' % name for name in names)
    result = subprocess.run([SHELL, '-eu', '-c', script], cwd=ROOT, env=dict(PATH='/usr/bin:/bin', **env),
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    return dict(zip(names, result.stdout.split('\n')))


class DefaultsTests(unittest.TestCase):
    def test_no_default_is_defined_in_two_scripts(self):
        seen = {}
        for script in deployed_scripts():
            for name in DEFAULT.findall(script.read_text()):
                seen.setdefault(name, []).append(script.name)
        self.assertEqual({name: where for name, where in seen.items() if len(where) > 1}, {})

    def test_the_shared_values_are_the_ones_every_copy_had(self):
        self.assertEqual(resolve(sorted(EXPECTED)), EXPECTED)

    def test_env_values_still_win(self):
        self.assertEqual(resolve(['WAN_IF', 'DIRECT_PUBLIC_DOMAINS'], WAN_IF='eth9', DIRECT_PUBLIC_DOMAINS='a.test'),
                         {'WAN_IF': 'eth9', 'DIRECT_PUBLIC_DOMAINS': 'a.test'})

    def test_every_script_using_a_shared_default_sources_defaults_sh(self):
        for script in deployed_scripts():
            if script.name == 'defaults.sh':
                continue
            text = script.read_text()
            used = sorted(name for name in EXPECTED if re.search(r'\$\{?' + name + r'\b', text))
            if used:
                self.assertRegex(text, SOURCES_DEFAULTS, '%s uses %s' % (script.name, ', '.join(used)))
                # After .env, so that its values win.
                env = text.find('.env')
                if env != -1:
                    self.assertLess(env, SOURCES_DEFAULTS.search(text).start(), script.name)


if __name__ == '__main__':
    unittest.main()

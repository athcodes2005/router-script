"""Diagnostic snapshots leave the router, so they must not carry secrets."""
import json
import os
import stat
import unittest

from sandbox import Sandbox

WIRELESS = {
    'mt798112': {'up': True, 'interfaces': [{'section': 'wifi5g', 'config': {
        'mode': 'ap', 'ssid': 'HostelNet', 'encryption': 'psk2',
        'key': 'S3cret-PSK', 'sae_password': 'sae"quoted\\pass', 'ieee80211k': True}}]},
}


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    # A13: snapshots showed neither the MSS clamps nor the marks nor the tun0 drop.
    def test_snapshots_record_the_mangle_table_the_input_chain_and_the_sets(self):
        result = self.box.run('diagnose.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        for tool in ('iptables', 'ip6tables'):
            self.assertEqual(self.box.count(tool + ' -t mangle -S'), 1, tool)
            self.assertEqual(self.box.count(tool + ' -S INPUT'), 1, tool)
        self.assertEqual(self.box.count('ipset list -t'), 1)
        self.assertIn('-A INPUT -i tun0 -m conntrack --ctstate NEW -j DROP', result.stdout)

    # N2: a DIAGNOSTICS_DIR set in .env was ignored here.
    def test_snapshots_honour_diagnostics_dir_from_env_file(self):
        alt = self.box.tmp / 'alt-diag'
        (self.box.proj / '.env').write_text('DIAGNOSTICS_DIR=%s\n' % alt)  # sandbox .env, not the real one
        result = self.box.run('collect_diagnostics.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(list(alt.glob('diagnostic_*.log'))), 1)

    def test_wireless_secrets_are_redacted(self):
        # F01: netifd's wireless status embeds each interface's WPA passphrase.
        (self.box.state / 'wireless.json').write_text(json.dumps(WIRELESS, indent=1))
        output = self.box.run('diagnose.sh').stdout
        for secret in ('S3cret-PSK', 'quoted', 'pass"'):
            self.assertNotIn(secret, output)
        self.assertIn('"key": "<redacted>"', output)
        self.assertIn('"sae_password": "<redacted>"', output)
        self.assertIn('HostelNet', output)
        self.assertIn('psk2', output)

    def test_warp_ipv6_probe_avoids_the_google_policy(self):
        # F15: until F43, google_wan_policy.sh rejected router IPv6 to Google,
        # so a Google probe reported WARP IPv6 as down on every snapshot.
        self.box.flag('google_v6_rejected')
        output = self.box.run('diagnose.sh').stdout
        self.assertIn('warp_ipv4_status=204', output)
        self.assertIn('warp_ipv6_status=200', output)

    def test_snapshots_are_owner_only(self):
        previous = os.umask(0o022)
        try:
            result = self.box.run('collect_diagnostics.sh')
        finally:
            os.umask(previous)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        snapshots = list((self.box.proj / 'diagnostics').glob('diagnostic_*.log'))
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(stat.S_IMODE(snapshots[0].stat().st_mode), 0o600)


if __name__ == '__main__':
    unittest.main()

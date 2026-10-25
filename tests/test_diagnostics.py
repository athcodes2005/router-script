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

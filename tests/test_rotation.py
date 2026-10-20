"""rotate_tunnel_ip.sh must validate the new WARP identity itself."""
import unittest

from sandbox import Sandbox

ORIGINAL = '{"dummy": "original-registration"}\n'
NEW = '{"dummy": "new-registration"}\n'


class RotationTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        proj = self.box.proj
        # Dummy registration files only; the real config.json never enters the sandbox.
        (proj / 'config.json').write_text(ORIGINAL)
        (proj / 'stop_tunnel.sh').write_text('exit 0\n')
        (proj / 'tunnel.sh').write_text('[ -f "$(dirname "$0")/config.json" ] || printf \'%s\\n\' \'{"dummy": "new-registration"}\' > "$(dirname "$0")/config.json"\n')
        # Google IPv6 is rejected by google_wan_policy.sh since 2026-09-23.
        self.box.flag('google_v6_rejected')

    def test_rotation_succeeds_when_warp_carries_both_families(self):
        # F09: the IPv6 check used Google, so every rotation rolled back.
        result = self.box.run('rotate_tunnel_ip.sh')
        self.assertEqual(result.returncode, 0, self.box.log('maintenance'))
        self.assertEqual((self.box.proj / 'config.json').read_text(), NEW)
        self.assertFalse((self.box.proj / 'config.json.previous').exists())

    def test_rotation_rolls_back_when_traffic_is_not_on_warp(self):
        self.box.flag('google_v6_rejected', on=False)
        self.box.flag('warp_trace_off')
        result = self.box.run('rotate_tunnel_ip.sh')
        self.assertEqual(result.returncode, 1, self.box.log('maintenance'))
        self.assertEqual((self.box.proj / 'config.json').read_text(), ORIGINAL)
        self.assertFalse((self.box.proj / 'config.json.previous').exists())


if __name__ == '__main__':
    unittest.main()

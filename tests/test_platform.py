"""A9: what the scripts assume about the firmware is checked once per boot."""
import unittest

from sandbox import Sandbox


class PlatformCheckTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        # Each boot starts with an empty /tmp; the template's tick already ran it.
        marker = self.box.tmp / 'router-script-platform-checked'
        if marker.exists():
            marker.unlink()

    def tick(self):
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.box.log('ensure')

    def test_a_matching_platform_is_reported_once_per_boot(self):
        self.assertEqual(self.tick().count('Platform check passed.'), 1)
        self.assertEqual(self.tick().count('Platform check passed.'), 1)

    def test_missing_tools_are_named(self):
        (self.box.bin / 'conntrack').unlink()
        (self.box.bin / 'jsonfilter').unlink()
        log = self.tick()
        self.assertIn('WARNING: platform check: jsonfilter is missing; '
                      'conntrack is missing, so game-session routes are off.', log)
        self.assertIn('Health check passed.', log)

    def test_renamed_radios_and_a_missing_firewall_hook_are_named(self):
        self.box.flag('wifi_sections_missing')
        self.box.flag('firewall_hook_missing')
        log = self.tick()
        self.assertIn('there is no radio wireless.mt798111; there is no radio wireless.mt798112; '
                      'the fw3 include is not registered (run install_firewall_hook.sh)', log)

    def test_a_wan_metric_that_beats_warp_is_named(self):
        self.box.flag('wan_metric_low')
        self.assertIn("the WAN default's metric 3 would beat WARP's 5", self.tick())

    def test_game_mode_lowers_the_wan_metric_on_purpose(self):
        self.box.flag('wan_metric_low')
        (self.box.tmp / 'router-script-game-mode').write_text('on\n')
        self.assertIn('Platform check passed.', self.tick())


if __name__ == '__main__':
    unittest.main()

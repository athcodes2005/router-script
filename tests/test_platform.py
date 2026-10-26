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

    # F52: what GL.iNet 4.11.0 changed passed the check unnoticed (report section 22).
    def add_ipv6_hook(self):
        hook = self.box.sysroot / 'etc/hotplug.d/iface/99-disable_ipv6'
        hook.parent.mkdir(parents=True)
        hook.write_text('# GL.iNet 4.11.0 turns IPv6 off on every ifup while its switch is off.\n')

    def test_gl_inets_ipv6_hook_is_named_while_its_switch_is_off(self):
        self.add_ipv6_hook()
        self.assertIn("GL.iNet's IPv6 switch is off, so its 99-disable_ipv6 hook turns IPv6 off on every ifup",
                      self.tick())

    def test_gl_inets_ipv6_hook_is_harmless_while_its_switch_is_on(self):
        self.add_ipv6_hook()
        self.box.flag('glipv6_switch_on')
        self.assertIn('Platform check passed.', self.tick())

    def test_a_stopped_doh_fallback_is_named(self):
        self.box.flag('dnsproxy_down')
        self.assertIn("dnsproxy is not running, so dnsmasq's primary encrypted upstream (127.0.0.1#5453) is dead",
                      self.tick())

    def test_a_dnsmasq_pid_file_the_blinkit_refresher_cannot_find_is_named(self):
        (self.box.sysroot / 'var/run/dnsmasq/dnsmasq.cfg01411c.pid').unlink()
        log = self.tick()
        self.assertIn('dnsmasq has no PID file under ', log)
        self.assertIn(', so Blinkit record changes cannot reach it', log)

    def test_sysupgrade_keep_list_missing_project_is_named(self):
        (self.box.sysroot / 'etc/sysupgrade.conf').write_text('/etc/config/gl_nas/\n')
        log = self.tick()
        self.assertIn('/etc/sysupgrade.conf does not list ', log)
        self.assertIn(', so a firmware upgrade will remove it (run bootstrap_router.sh)', log)

    def test_bootstrap_registers_sysupgrade_keep_entries(self):
        conf = self.box.sysroot / 'etc/sysupgrade.conf'
        conf.write_text('/etc/config/gl_nas/\n')
        res = self.box.run('bootstrap_router.sh')
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        lines = conf.read_text().splitlines()
        self.assertIn('%s/' % self.box.proj, lines)
        self.assertIn('%s/etc/router-script/' % self.box.sysroot, lines)


if __name__ == '__main__':
    unittest.main()

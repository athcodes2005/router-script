"""A2/A4: a failed dnsproxy restart must not abort DNS repair; a dead dnsproxy is restarted."""
import unittest

from sandbox import SHELL, Sandbox, _write_exec

FAILING_INIT = '#!%s\nprintf \'%%s\\n\' "${0##*/} $*" >> "$SIM_LOG"\nexit 1\n' % SHELL


class DnsproxyRestartTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.init = self.box.sysroot / 'etc/init.d/dnsproxy'

    def configure(self):
        return self.box.run('configure_dns.sh')

    def tick(self):
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.box.log('ensure')

    # A2
    def test_failed_dnsproxy_restart_does_not_abort_dns_repair(self):
        _write_exec(self.init, FAILING_INIT)
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('dnsproxy restart failed', result.stdout)
        self.assertEqual(self.box.count('dnsproxy restart'), 1)
        self.assertEqual(self.box.count('dnsmasq restart'), 1)
        self.assertIn('uci commit dhcp', self.box.calls())

    # A4
    def test_dead_dnsproxy_is_restarted_once_and_logged(self):
        self.box.flag('dnsproxy_down')
        log = self.tick()
        self.assertEqual(self.box.count('dnsproxy restart'), 1)
        self.assertEqual(log.count('dnsproxy is not running; restarting it.'), 1)

    # A dnsproxy that died again at once was restarted on every tick.
    def test_a_dnsproxy_that_keeps_dying_is_restarted_once_per_cooldown(self):
        self.box.flag('dnsproxy_down')
        for _ in range(3):
            self.tick()
        self.assertEqual(self.box.count('dnsproxy restart'), 1)
        marker = self.box.tmp / 'router-script-dnsproxy-retry-after'
        marker.write_text('1\n')  # the cooldown is over
        self.tick()
        self.assertEqual(self.box.count('dnsproxy restart'), 2)
        self.box.flag('dnsproxy_down', False)
        self.tick()
        self.assertFalse(marker.exists())

    def test_failed_liveness_restart_warns_and_the_tick_continues(self):
        self.box.flag('dnsproxy_down')
        _write_exec(self.init, FAILING_INIT)
        log = self.tick()
        self.assertEqual(self.box.count('dnsproxy restart'), 1)
        self.assertIn('dnsproxy restart failed', log)
        self.assertIn('Health check passed.', log)

    def test_live_dnsproxy_is_left_alone(self):
        self.tick()
        self.assertEqual(self.box.count('dnsproxy restart'), 0)

    def test_routers_without_dnsproxy_are_left_alone(self):
        self.init.unlink()
        self.box.flag('dnsproxy_down')
        log = self.tick()
        self.assertEqual(self.box.count('dnsproxy restart'), 0)
        self.assertNotIn('restarting it', log)


# A3: the two gl-dns-v2 keys had no recorded reason. Measured on firmware
# 4.11.0 (2026-11-13): the init script needs them, and they make the firmware
# apply its own DNS settings again at every boot.
class FirmwareDnsSettingsTests(unittest.TestCase):
    FIRMWARE_YAML = ('---\nupstream:\n  - "sdns://AgYAAAAAAAAACDkuOS45LjEy"\n  - "sdns://AgYAAAAAAAAADVsyNjIwOmZlOjoxMl0"\n'
                     'fallback:\n  - "tls://9.9.9.9:853"\nlisten-ports:\n  - 5453\ncache-optimistic: true\n')

    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.yaml = self.box.sysroot / 'etc/dnsproxy/dnsproxy.yaml'

    # GL.iNet's init script returns without starting dnsproxy unless mode is
    # 'secure' and proto is not 'odoh'.
    def test_the_firmware_is_told_to_run_dnsproxy_before_it_is_restarted(self):
        result = self.box.run('configure_dns.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.box.calls()
        restart = calls.index('dnsproxy restart')
        for setting in ("uci set gl-dns-v2.@dns[0].mode=secure", "uci set gl-dns-v2.@dns[0].proto=doh",
                        'uci commit gl-dns-v2'):
            self.assertIn(setting, calls)
            self.assertLess(calls.index(setting), restart)

    # /etc/init.d/gl_dns: the upstreams become the admin panel's servers, the
    # dnsmasq server list shrinks to dnsproxy alone and cachesize is removed.
    def test_the_firmware_reapplying_its_settings_at_boot_is_repaired(self):
        self.yaml.write_text(self.FIRMWARE_YAML)
        self.box.flag('dns_firmware_reset')
        self.box.flag('cachesize_unset')
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DNS configuration drift detected. Reapplying configure_dns.sh.', self.box.log('ensure'))
        restored = self.yaml.read_text()
        self.assertIn('tls://1.1.1.1:853', restored)
        self.assertNotIn('sdns://', restored)
        calls = self.box.calls()
        for server in ('8.8.8.8', '10.200.1.11', '/moodle.iitb.ac.in/10.200.1.11'):
            self.assertIn('uci add_list dhcp.@dnsmasq[0].server=%s' % server, calls)
        self.assertIn('uci set dhcp.@dnsmasq[0].cachesize=4000', calls)

    def test_each_firmware_change_alone_counts_as_drift(self):
        for change in ('yaml', 'dns_firmware_reset', 'cachesize_unset'):
            box = Sandbox.fresh(self)
            if change == 'yaml':
                (box.sysroot / 'etc/dnsproxy/dnsproxy.yaml').write_text(self.FIRMWARE_YAML)
            else:
                box.flag(change)
            box.run('ensure_network.sh')
            self.assertIn('DNS configuration drift detected', box.log('ensure'), change)


if __name__ == '__main__':
    unittest.main()

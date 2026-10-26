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


if __name__ == '__main__':
    unittest.main()

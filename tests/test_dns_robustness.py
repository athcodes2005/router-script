"""A2: a failed dnsproxy restart must not abort DNS repair."""
import unittest

from sandbox import SHELL, Sandbox, _write_exec

FAILING_INIT = '#!%s\nprintf \'%%s\\n\' "${0##*/} $*" >> "$SIM_LOG"\nexit 1\n' % SHELL


class DnsproxyRestartTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.init = self.box.sysroot / 'etc/init.d/dnsproxy'

    def configure(self):
        return self.box.run('configure_dns.sh')

    # A2
    def test_failed_dnsproxy_restart_does_not_abort_dns_repair(self):
        _write_exec(self.init, FAILING_INIT)
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('dnsproxy restart failed', result.stdout)
        self.assertEqual(self.box.count('dnsproxy restart'), 1)
        self.assertEqual(self.box.count('dnsmasq restart'), 1)
        self.assertIn('uci commit dhcp', self.box.calls())


if __name__ == '__main__':
    unittest.main()

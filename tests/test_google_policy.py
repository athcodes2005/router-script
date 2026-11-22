"""google_wan_policy.sh runs on every health tick: check-dns, then the policy itself."""
import unittest

from sandbox import Sandbox, SHELL

SETS = ('google_net6', 'google_dns6')
ACCEPT = '-i br-lan -o tun0 -j ACCEPT'


class GooglePolicyTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def count_text_tools(self):
        # Wrap the real tools so each process the check spawns is logged.
        for name in ('tr', 'grep', 'awk'):
            target = (self.box.bin / name).resolve()
            (self.box.bin / name).unlink()
            (self.box.bin / name).write_text('#!%s\nprintf "%%s\\n" "%s" >> "$SIM_LOG"\nexec %s "$@"\n' % (SHELL, name, target))
            (self.box.bin / name).chmod(0o755)

    def test_disabled_by_default_cleans_up_active_rules_once(self):
        # First install the policy, then run with the default GOOGLE_WAN_POLICY=0.
        self.assertEqual(self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1').returncode, 0)
        self.box.calls_file.write_text('')
        result = self.box.run('google_wan_policy.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Google WAN policy disabled; removed active direct-WAN Google rules.', result.stdout)
        # No Google mangle, ip6tables, ip rules or ipsets remain.
        self.assertNotIn('google_net4', (self.box.state / 'iptables.rules').read_text())
        self.assertNotIn('google_dns4', (self.box.state / 'iptables.rules').read_text())
        self.assertNotIn('google_net6', (self.box.state / 'ip6tables.rules').read_text())
        self.assertNotIn('google_dns6', (self.box.state / 'ip6tables.rules').read_text())
        self.assertNotIn('710:', (self.box.state / 'ip.rules').read_text())
        self.assertNotIn('690:', (self.box.state / 'ip.rules').read_text())
        # Second run is a silent no-op.
        self.box.calls_file.write_text('')
        second = self.box.run('google_wan_policy.sh')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, '')

    def test_disabled_check_dns_flags_leftover_google_ipset_entries(self):
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns').returncode, 0)
        self.box.flag('google_ipset_present')
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns').returncode, 1)
        self.assertEqual(self.box.run('google_wan_policy.sh', 'configure-dns').returncode, 0)
        self.assertTrue(any('uci del_list dhcp.@dnsmasq[0].ipset=/google.com/google_dns4,google_dns6' in c
                            for c in self.box.calls()))

    def test_complete_ipset_list_passes(self):
        self.box.flag('google_ipset_present')
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns', GOOGLE_WAN_POLICY='1').returncode, 0)

    def test_missing_domain_is_reported(self):
        self.box.flag('google_ipset_drift')
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns', GOOGLE_WAN_POLICY='1').returncode, 1)

    def test_check_is_a_single_pass(self):
        # F11: a tr|grep pair per domain cost about 165 processes per tick.
        self.box.flag('google_ipset_present')
        self.count_text_tools()
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns', GOOGLE_WAN_POLICY='1').returncode, 0)
        spawned = [line for line in self.box.calls() if line in ('tr', 'grep', 'awk')]
        self.assertLessEqual(len(spawned), 3, spawned[:5])


class GoogleIPv6Tests(unittest.TestCase):
    """When enabled (GOOGLE_WAN_POLICY=1), LAN Google IPv6 is rejected for IPv4 fallback."""

    def setUp(self):
        self.box = Sandbox.fresh(self)
        self.rules_file = self.box.state / 'ip6tables.rules'
        self.box.flag('google_ipset_present')
        self.assertEqual(self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1').returncode, 0)

    def rules(self, chain):
        prefix = 'filter %s ' % chain
        return [line[len(prefix):] for line in self.rules_file.read_text().splitlines() if line.startswith(prefix)]

    def google_rules(self, chain):
        return [rule for rule in self.rules(chain) if '--match-set google_' in rule]

    # F43: BusyBox ntpd resolved time1.google.com to its IPv6 address once WARP
    # was up, and this reject failed every send, so on 25 October the clock
    # stayed 91 minutes slow for hours. Single-address tools never fall back.
    def test_router_traffic_to_google_ipv6_is_not_rejected(self):
        self.assertEqual(self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1').returncode, 0)
        self.assertEqual(self.google_rules('OUTPUT'), [])
        self.assertEqual(len(self.google_rules('FORWARD')), 4)

    def test_upgrade_removes_the_old_output_rejects(self):
        old = ['filter OUTPUT -p tcp -m set --match-set %s dst -j REJECT --reject-with tcp-reset' % s for s in SETS]
        old += ['filter OUTPUT -m set --match-set %s dst -j REJECT --reject-with icmp6-port-unreachable' % s for s in SETS]
        with self.rules_file.open('a') as rules:
            rules.write('\n'.join(old) + '\n')
        self.assertEqual(self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1').returncode, 0)
        self.assertEqual(self.google_rules('OUTPUT'), [])
        self.assertEqual(len(self.google_rules('FORWARD')), 4)

    def move_accept_to_top(self):
        """What stop_tunnel.sh and then tunnel.sh (or the F03 repair) do to the ACCEPT."""
        lines = [line for line in self.rules_file.read_text().splitlines() if line != 'filter FORWARD ' + ACCEPT]
        self.rules_file.write_text('\n'.join(['filter FORWARD ' + ACCEPT] + lines) + '\n')

    def assert_rejects_first(self):
        forward = self.rules('FORWARD')
        google = [i for i, rule in enumerate(forward) if '--match-set google_' in rule]
        self.assertEqual(len(google), 4, forward)
        self.assertEqual(forward.count(ACCEPT), 1, forward)
        self.assertLess(max(google), forward.index(ACCEPT), forward)

    # F44: tunnel.sh and the health check insert the LAN->tun0 ACCEPT at the top
    # of FORWARD whenever it is missing, as after every WARP restart. The rejects
    # below it never matched: on 25 October the LAN reached Google over IPv6.
    def test_rejects_move_back_above_the_lan_to_warp_accept(self):
        self.move_accept_to_top()
        result = self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_rejects_first()
        self.assertIn('Google IPv6 rejects reinstalled above the LAN to tun0 accept.', result.stdout)

    def test_rejects_in_order_are_left_alone(self):
        self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1')
        before = self.rules_file.read_text()
        self.box.calls_file.write_text('')
        result = self.box.run('google_wan_policy.sh', GOOGLE_WAN_POLICY='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rules_file.read_text(), before)
        self.assertEqual([c for c in self.box.calls() if c.startswith(('ip6tables -I', 'ip6tables -D'))], [])
        self.assertNotIn('reinstalled', result.stdout)

    def test_the_next_health_check_restores_the_order(self):
        self.move_accept_to_top()
        self.assertEqual(self.box.run('ensure_network.sh', GOOGLE_WAN_POLICY='1').returncode, 0, self.box.log('ensure'))
        self.assert_rejects_first()
        self.assertIn('Health check passed.', self.box.log('ensure'))


if __name__ == '__main__':
    unittest.main()

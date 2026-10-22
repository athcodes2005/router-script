"""F41: game mode isolates IPv6 with a REJECT rule; dnsmasq 2.85 cannot filter AAAA."""
import unittest

from sandbox import Sandbox

REJECT = 'filter FORWARD -i br-lan -o tun0 -j REJECT'


class GameModeTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def forward_rules(self):
        lines = (self.box.state / 'ip6tables.rules').read_text().splitlines()
        return [line for line in lines if line.startswith('filter FORWARD ')]

    # The init script ignores filter_aaaa, so toggling it only reloaded dnsmasq.
    def test_game_mode_isolates_ipv6_without_touching_dnsmasq(self):
        result = self.box.run('game_mode.sh', 'on')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.forward_rules()[0], REJECT)  # ahead of the LAN->tun0 ACCEPT
        result = self.box.run('game_mode.sh', 'off')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(REJECT, self.forward_rules())
        for call in ('uci set dhcp.@dnsmasq[0].filter_aaaa', 'uci commit dhcp', 'dnsmasq reload'):
            self.assertEqual(self.box.count(call), 0, call)

    def test_filter_aaaa_stays_off_in_game_mode_too(self):
        (self.box.tmp / 'router-script-game-mode').write_text('on\n')
        self.box.flag('filter_aaaa_on')
        self.box.run('ensure_network.sh')
        self.assertIn('LAN IPv6 configuration drift detected', self.box.log('ensure'))
        self.assertIn('uci set dhcp.@dnsmasq[0].filter_aaaa=0', self.box.calls())


if __name__ == '__main__':
    unittest.main()

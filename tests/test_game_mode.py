"""F41: game mode isolates IPv6 with a REJECT rule; dnsmasq 2.85 cannot filter AAAA."""
import subprocess
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

    # Game mode sends all public traffic around WARP and had no end: left on,
    # it stayed until the next reboot while every health check "passed".
    def uptime(self, seconds):
        path = self.box.sysroot / 'proc/uptime'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('%d.42 9000.00\n' % seconds)

    def expiry_tick(self, marker, uptime, **env):
        path = self.box.tmp / 'router-script-game-mode'
        path.write_text(marker)
        self.uptime(uptime)
        result = self.box.run('ensure_network.sh', **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return path.exists(), self.box.log('ensure')

    def test_turning_game_mode_on_records_the_uptime(self):
        self.uptime(1234)
        result = self.box.run('game_mode.sh', 'on')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.box.tmp / 'router-script-game-mode').read_text(), 'on 1234\n')
        self.assertIn('game_mode turns itself off after 480 minutes.', self.box.log('ensure'))

    def test_game_mode_left_on_is_turned_off_after_the_limit(self):
        on, log = self.expiry_tick('on 100\n', 100 + 28800)
        self.assertFalse(on)
        self.assertIn('Game mode has been on for over 8h; turning it off', log)
        self.assertIn('game_mode OFF: WARP default restored', log)
        self.assertRegex(log, r'Health check passed\.\n')  # and this run checks WARP again
        self.assertNotIn(REJECT, self.forward_rules())

    def test_game_mode_within_the_limit_stays_on(self):
        on, log = self.expiry_tick('on 100\n', 100 + 28799)
        self.assertTrue(on)
        self.assertIn('Health check passed (game_mode: direct WAN preferred).', log)

    def test_the_limit_can_be_changed_or_turned_off(self):
        on, _ = self.expiry_tick('on 100\n', 100 + 600, GAME_MODE_MAX_SECONDS='600')
        self.assertFalse(on)
        on, _ = self.expiry_tick('on 100\n', 10 ** 7, GAME_MODE_MAX_SECONDS='0')
        self.assertTrue(on)

    def test_a_marker_without_a_time_is_left_alone(self):
        on, _ = self.expiry_tick('on\n', 10 ** 7)  # turned on by an older game_mode.sh
        self.assertTrue(on)

    # A5: the trailing status call re-exec'd a bare "$0", which is not in PATH.
    def test_on_and_off_report_status_when_run_by_bare_filename(self):
        for mode in ('on', 'off'):
            result = subprocess.run(['sh', 'game_mode.sh', mode], cwd=self.box.proj, env=self.box.env(),
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('game_mode', result.stdout)
            self.assertNotIn('not found', result.stderr)


if __name__ == '__main__':
    unittest.main()

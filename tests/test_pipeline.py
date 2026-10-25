"""Whole-script runs of the health pipeline inside the isolated sandbox."""
from email.utils import formatdate
import os
import re
import time
import unittest

from sandbox import Sandbox

DISRUPTIVE = ('ifdown', 'ifup', 'wifi reload', 'dnsmasq restart', 'dnscrypt-proxy restart', 'killall')


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def test_healthy_tick_passes_without_disruptive_actions(self):
        result = self.box.run('ensure_network.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Health check passed.', self.box.log('ensure'))
        for action in DISRUPTIVE:
            self.assertEqual(self.box.count(action), 0, action)

    def tick(self, **env):
        return self.box.run('ensure_network.sh', **env)

    # F02: a stuck Wi-Fi or DNS stage must not block WAN, portal and WARP recovery.
    def test_wifi_config_failure_does_not_block_tunnel_recovery(self):
        self.box.flag('wifi_drift')
        self.box.flag('warp_down')
        self.tick()
        log = self.box.log('ensure')
        self.assertIn('Wi-Fi stability configuration drift detected', log)
        self.assertIn('Tunnel health check failed: process missing. Restarting tunnel.', log)

    # A2: the other optional stages must not block recovery either.
    def test_lan_ipv6_failure_does_not_block_tunnel_recovery(self):
        self.box.flag('filter_aaaa_on')  # LAN IPv6 drift that its repair cannot fix
        self.box.flag('warp_down')
        self.tick()
        log = self.box.log('ensure')
        self.assertIn('LAN IPv6 remains invalid after repair', log)
        self.assertIn('Tunnel health check failed: process missing. Restarting tunnel.', log)

    def test_google_policy_failure_does_not_block_tunnel_recovery(self):
        self.box.flag('ipset_fail')
        self.box.flag('warp_down')
        self.tick()
        log = self.box.log('ensure')
        self.assertIn('Google WAN policy deferred', log)
        self.assertIn('Tunnel health check failed: process missing. Restarting tunnel.', log)

    def test_persistent_radio_failure_is_reloaded_once_per_cooldown(self):
        self.box.flag('wifi_down')
        self.tick()
        self.tick()
        self.assertEqual(self.box.count('wifi reload'), 1)
        self.assertIn('Wi-Fi remains degraded; repair cooldown is active.', self.box.log('ensure'))

    def test_dns_config_drift_does_not_block_portal_recovery(self):
        self.box.flag('dns_drift')
        self.box.flag('direct_down')
        self.tick()
        log = self.box.log('ensure')
        self.assertIn('DNS configuration drift detected', log)
        self.assertIn('IPv4 internet check failed twice. Running login.sh.', log)

    def test_persistent_dns_config_repair_is_rate_limited(self):
        self.box.flag('dns_drift')
        self.tick()
        self.tick()
        self.assertEqual(self.box.count('dnsmasq restart'), 1)
        self.assertIn('Health check passed.', self.box.log('ensure'))

    def test_dead_resolver_still_stops_before_probe_driven_recovery(self):
        self.box.flag('dnsmasq_down')
        self.box.flag('direct_down')
        self.assertEqual(self.tick().returncode, 1)
        self.assertEqual(self.tick().returncode, 1)
        self.assertEqual(self.box.log('login'), '')
        self.assertEqual(self.box.count('dnsmasq restart'), 1)
        # F28: the probe name is pinned locally, so this tests dnsmasq, not campus DNS.
        log = self.box.log('ensure')
        self.assertIn('dnsmasq is not running or not answering locally', log)
        self.assertNotIn('campus resolution failed', log)

    # F22: with strict-order the upstream order is the invariant, and only the
    # listed campus hosts may be forwarded to campus DNS.
    def test_upstream_order_drift_is_repaired(self):
        self.box.flag('dns_order_drift')
        self.tick()
        self.assertIn('DNS configuration drift detected', self.box.log('ensure'))

    def test_whole_campus_zone_forward_is_repaired(self):
        self.box.flag('dns_zone_forward')
        self.tick()
        self.assertIn('DNS configuration drift detected', self.box.log('ensure'))

    # F04: cycling the WAN releases the lease (a new address, every flow reset).
    def test_missing_campus_route_is_reinstalled_without_wan_cycle(self):
        self.box.flag('campus_route_tun')
        self.box.flag('campus_route_fixable')
        self.tick()
        self.assertEqual(self.box.count('ifdown'), 0)
        self.assertEqual(self.box.count('ip route replace 10.0.0.0/8 via 10.1.40.250 dev eth0 metric 1'), 1)
        self.assertEqual(self.box.count('ip route replace 103.21.124.0/22 via 10.1.40.250 dev eth0 metric 1'), 1)
        self.assertIn('Health check passed.', self.box.log('ensure'))

    def test_unrepairable_campus_route_still_cycles_the_wan(self):
        self.box.flag('campus_route_tun')
        self.tick()
        self.assertEqual(self.box.count('ifdown wan'), 1)

    # F06: retention keeps 24 snapshots; one per tick evicts the incident's onset.
    def test_persistent_failure_is_snapshotted_once(self):
        self.box.flag('wan_down')
        self.assertEqual(self.tick().returncode, 1)
        self.assertEqual(self.tick().returncode, 1)
        snapshots = list((self.box.proj / 'diagnostics').glob('diagnostic_*.log'))
        self.assertEqual(len(snapshots), 1)
        self.assertIn('captured recently', self.box.log('ensure'))

    # F07: a lower-metric default bypasses WARP while tun0-bound probes pass.
    def test_public_route_bypass_is_reported_without_restart(self):
        self.box.flag('route_bypass')
        self.assertEqual(self.tick().returncode, 0)
        log = self.box.log('ensure')
        self.assertIn('WARNING: public traffic does not prefer tun0', log)
        self.assertIn('Health check passed.', log)
        self.assertNotIn('Restarting tunnel', log)

    # F20: the refreshers share /32s; one dropping a route must not delete it
    # while another still lists it. The stubs resolve every public name to
    # 198.51.100.10 and show one game session to 44.252.91.204.
    def test_game_refresher_keeps_a_route_the_public_refresher_lists(self):
        (self.box.tmp / 'router-script-game-session-host-routes').write_text('198.51.100.10/32\n')
        self.tick()
        self.assertEqual(self.box.count('ip route del 198.51.100.10/32'), 0)

    def test_public_refresher_keeps_a_route_the_game_refresher_lists(self):
        (self.box.tmp / 'router-script-direct-public-host-routes').write_text('44.252.91.204/32\n')
        self.tick()
        self.assertEqual(self.box.count('ip route del 44.252.91.204/32'), 0)

    def test_route_no_refresher_lists_is_still_removed(self):
        (self.box.tmp / 'router-script-direct-public-host-routes').write_text('203.0.113.9/32\n')
        self.tick()
        self.assertEqual(self.box.count('ip route del 203.0.113.9/32 via 10.1.40.250 dev eth0 metric 1'), 1)

    # F12: on a healthy tick the public refresher resolves the Blinkit names
    # through dnsmasq, which serves the Blinkit hosts file, so an address that
    # leaves the file loses its route on that tick.
    def test_replaced_blinkit_address_loses_its_route(self):
        upstream = self.box.state / 'blinkit_upstream'
        upstream.write_text('198.51.100.30\n')
        self.tick()
        upstream.write_text('198.51.100.40\n')
        self.tick()
        self.assertEqual(self.box.count('ip route del 198.51.100.30/32 via 10.1.40.250 dev eth0 metric 1'), 1)
        self.assertEqual(self.box.count('ip route del 198.51.100.40/32'), 0)

    # F14: a reachable but slow tunnel (the 08-07/08-09 failure class) passes
    # every probe. Restarting on latency caused false restarts, so only report.
    def test_sustained_slow_tunnel_is_reported_without_restart(self):
        self.box.flag('tunnel_slow')
        self.tick()
        self.tick()
        self.assertNotIn('WARNING: the tunnel probe', self.box.log('ensure'))
        self.assertEqual(self.tick().returncode, 0)
        log = self.box.log('ensure')
        self.assertIn('WARNING: the tunnel probe took over 1.5s on 3 consecutive checks '
                      '(latest 2.400s); not restarting.', log)
        self.assertNotIn('Restarting tunnel', log)
        self.assertEqual(len(list((self.box.proj / 'diagnostics').glob('diagnostic_*.log'))), 1)

    def test_one_fast_check_resets_the_slow_count(self):
        for slow in (True, True, False, True, True):
            self.box.flag('tunnel_slow', slow)
            self.tick()
        self.assertNotIn('WARNING: the tunnel probe', self.box.log('ensure'))

    # F21: after a reboot the clock can be months behind until NTP syncs, which
    # breaks lock ageing and TLS. The script's own mtime is a lower bound.
    def test_clock_behind_the_script_is_reported(self):
        self.tick()
        self.assertNotIn('WARNING: the clock reads', self.box.log('ensure'))
        future = time.time() + 86 * 86400
        os.utime(self.box.proj / 'ensure_network.sh', (future, future))
        self.assertEqual(self.tick().returncode, 0)
        log = self.box.log('ensure')
        self.assertIn("earlier than this script's modification time", log)
        self.assertIn('Health check passed.', log)

    def fake_uptime(self, seconds):
        uptime = self.box.sysroot / 'proc/uptime'
        uptime.parent.mkdir(parents=True, exist_ok=True)
        uptime.write_text('%d.42 9000.00\n' % seconds)

    def clock_check_due(self, server_offset):
        """The probe's Date header reads our clock plus server_offset seconds."""
        (self.box.state / 'http_date').write_text(formatdate(time.time() + server_offset, usegmt=True) + '\n')
        # The check is scheduled by uptime; without /proc/uptime it never runs.
        self.fake_uptime(7000)
        (self.box.tmp / 'router-script-clock-checked-at').unlink(missing_ok=True)

    def date_requests(self):
        return [call for call in self.box.calls() if call.startswith('curl ') and ' -D - ' in call]

    def clock_warnings(self):
        return re.findall(r'WARNING: the clock is (\d+)s (behind|ahead of) the Date header from (\S+)\. ',
                          self.box.log('ensure'))

    def clock_warning(self):
        warnings = self.clock_warnings()
        self.assertEqual(len(warnings), 1, self.box.log('ensure'))
        return warnings[0]

    # F45: on 25 October the clock stayed 91 minutes slow for hours, and F21's
    # check said nothing: the clock was still later than the scripts' mtime.
    def test_clock_behind_the_probe_date_is_reported(self):
        self.clock_check_due(5477)
        self.assertEqual(self.tick().returncode, 0)
        seconds, direction, url = self.clock_warning()
        self.assertAlmostEqual(int(seconds), 5477, delta=10)
        self.assertEqual((direction, url), ('behind', 'https://www.google.com/generate_204'))
        self.assertIn('Health check passed.', self.box.log('ensure'))

    def test_clock_ahead_of_the_probe_date_is_reported(self):
        self.clock_check_due(-600)
        self.assertEqual(self.tick().returncode, 0)
        seconds, direction, _ = self.clock_warning()
        self.assertAlmostEqual(int(seconds), 600, delta=10)
        self.assertEqual(direction, 'ahead of')

    def test_a_clock_within_two_minutes_is_not_reported(self):
        self.clock_check_due(60)
        self.assertEqual(self.tick().returncode, 0)
        self.assertEqual(self.clock_warnings(), [])
        self.assertEqual(len(self.date_requests()), 1)

    def test_the_clock_is_checked_once_per_interval_of_uptime(self):
        self.clock_check_due(5477)
        self.tick()
        self.tick()
        self.assertEqual(len(self.clock_warnings()), 1)
        self.fake_uptime(7000 + 600)
        self.tick()
        self.assertEqual(len(self.clock_warnings()), 2)
        self.assertEqual(len(self.date_requests()), 2)

    def test_a_date_header_it_cannot_read_is_ignored(self):
        self.clock_check_due(0)
        (self.box.state / 'http_date').write_text('yesterday\n')
        self.assertEqual(self.tick().returncode, 0)
        self.assertEqual(self.clock_warnings(), [])
        self.assertIn('Health check passed.', self.box.log('ensure'))

    # F12: refresh_blinkit_dns.sh publishes on every tick, but the public
    # refresher runs only on healthy ones. A record set replaced while WARP was
    # down or game mode was on kept its routes forever (20 found on 2026-10-22).
    def test_blinkit_routes_replaced_while_warp_is_down_are_removed(self):
        upstream = self.box.state / 'blinkit_upstream'
        self.box.flag('warp_down')
        self.tick()  # the restart fails: direct fallback, public route file removed
        upstream.write_text('198.51.100.30\n')
        self.tick()
        upstream.write_text('198.51.100.40\n')
        self.tick()
        self.assertIn('Tunnel retry is cooling down', self.box.log('ensure'))
        self.assertEqual(self.box.count('ip route del 198.51.100.30/32 via 10.1.40.250 dev eth0 metric 1'), 1)
        self.assertEqual(self.box.count('ip route del 198.51.100.40/32'), 0)

    def test_blinkit_routes_replaced_in_game_mode_are_removed(self):
        upstream = self.box.state / 'blinkit_upstream'
        (self.box.tmp / 'router-script-game-mode').write_text('on\n')
        upstream.write_text('198.51.100.30\n')
        self.tick()
        upstream.write_text('198.51.100.40\n')
        self.tick()
        self.assertIn('Health check passed (game_mode: direct WAN preferred).', self.box.log('ensure'))
        self.assertEqual(self.box.count('ip route del 198.51.100.30/32 via 10.1.40.250 dev eth0 metric 1'), 1)
        # The pre-game-mode address is still listed for the other public names.
        self.assertEqual(self.box.count('ip route del 198.51.100.10/32'), 0)

    # F31: fw3 filters input only from br-lan and eth0 and INPUT's policy is
    # ACCEPT, so new connections arriving on tun0 reached SSH, the admin UI and DNS.
    TUN0_DROP = 'filter INPUT -i tun0 -m conntrack --ctstate NEW -j DROP'

    def rules(self, tool):
        return (self.box.state / (tool + '.rules')).read_text().splitlines()

    def drop_tun0_rule(self, tool):  # what a firewall reload does
        kept = [line for line in self.rules(tool) if line != self.TUN0_DROP]
        (self.box.state / (tool + '.rules')).write_text(''.join(line + '\n' for line in kept))

    def test_new_inbound_connections_on_tun0_are_dropped(self):
        for tool in ('iptables', 'ip6tables'):
            self.assertIn(self.TUN0_DROP, self.rules(tool), tool)

    def test_tun0_drop_lost_in_a_firewall_reload_is_restored_once(self):
        for tool in ('iptables', 'ip6tables'):
            self.drop_tun0_rule(tool)
        self.tick()
        self.tick()
        for tool in ('iptables', 'ip6tables'):
            self.assertIn(self.TUN0_DROP, self.rules(tool), tool)
            self.assertEqual(self.box.count(tool + ' -I INPUT -i tun0'), 1, tool)
        self.assertIn('Added the missing ip6tables rule dropping new inbound connections on tun0.',
                      self.box.log('ensure'))

    def test_tun0_drop_is_kept_in_game_mode(self):
        (self.box.tmp / 'router-script-game-mode').write_text('on\n')
        self.drop_tun0_rule('iptables')
        self.tick()
        self.assertIn(self.TUN0_DROP, self.rules('iptables'))

    def test_tun0_drop_failure_never_restarts_warp(self):
        self.box.flag('input_rule_fail')
        self.drop_tun0_rule('iptables')
        self.assertEqual(self.tick().returncode, 0)
        log = self.box.log('ensure')
        self.assertIn('WARNING: could not add the iptables rule dropping new inbound connections on tun0.', log)
        self.assertIn('Health check passed.', log)
        self.assertNotIn('Restarting tunnel', log)

    # F08: tearing the game policy down each tick left new sessions unmarked.
    def test_healthy_tick_leaves_game_policy_untouched(self):
        self.tick()
        for call in ('iptables -t mangle -F GAME_SESSION_POLICY', 'iptables -t mangle -D PREROUTING',
                     'iptables -t mangle -I PREROUTING', 'ip rule del', 'ip rule add'):
            self.assertEqual(self.box.count(call), 0, call)
        self.assertIn('Health check passed.', self.box.log('ensure'))


if __name__ == '__main__':
    unittest.main()

"""Run real shell functions with fake network commands; never touch live routes."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'ensure_network.sh').read_text()

def function(name):
    match = re.search(r'^' + name + r'\(\) [\{\(]\n.*?^[\}\)]\n', SOURCE, re.M | re.S)
    assert match, name
    return match.group()

class RecoveryTests(unittest.TestCase):
    def run_shell(self, code, env=None):
        result = subprocess.run(['sh', '-eu', '-c', code], text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_game_policy_uses_default_lan_without_env_override(self):
        defaults = SOURCE[SOURCE.index('WAN_IF='):SOURCE.index('# DNS servers expected')]
        self.run_shell(defaults + function('ensure_game_session_policy') + r"""
        ip() {
            case "$*" in
                '-4 route show default dev eth0') echo 'default via 10.1.40.250 dev eth0';;
                'rule del '*) return 1;;
                *) printf '%s\n' "$*";;
            esac
        }
        iptables() { case "$*" in *' -C '*) return 1;; esac; return 0; }
        ensure_game_session_policy
        """).index('route replace 192.168.8.0/24 dev br-lan table 101')

    def test_transient_failure_does_not_require_restart(self):
        self.run_shell(function('tunnel_healthy_confirmed') + '''
        log() { :; }; sleep() { :; }; ip() { return 0; }
        tunnel_process_ok() { return 0; }
        count=0
        tunnel_healthy() { count=$((count+1)); TUNNEL_FAILURE_REASON=probe; [ "$count" -ge 2 ]; }
        TUN_IF=tun0; TUNNEL_CONFIRM_DELAY=3
        tunnel_healthy_confirmed
        [ "$count" -eq 2 ]
        ''')

    def test_persistent_failure_still_requests_recovery(self):
        self.run_shell(function('tunnel_healthy_confirmed') + '''
        log() { :; }; sleep() { :; }; ip() { return 0; }
        tunnel_process_ok() { return 0; }
        tunnel_healthy() { TUNNEL_FAILURE_REASON=probe; return 1; }
        TUN_IF=tun0; TUNNEL_CONFIRM_DELAY=3
        if tunnel_healthy_confirmed; then exit 1; fi
        ''')

    def test_missing_process_recovers_without_delay(self):
        self.run_shell(function('tunnel_healthy_confirmed') + '''
        log() { :; }; sleep() { exit 9; }
        tunnel_process_ok() { return 1; }
        tunnel_healthy() { TUNNEL_FAILURE_REASON=process; return 1; }
        if tunnel_healthy_confirmed; then exit 1; fi
        ''')

    def test_optional_route_failure_does_not_affect_liveness(self):
        self.run_shell(function('tunnel_healthy') + '''
        tunnel_process_ok() { :; }; ip() { :; }; tunnel_ready_ok() { :; }
        tunnel_routes_ok() { :; }; campus_core_route_ok() { :; }; nat_rules_ok() { :; }
        tunnel_internet_v4_ok() { :; }
        refresh_optional_routes() { exit 9; }
        TUN_IF=tun0
        tunnel_healthy
        [ -z "$TUNNEL_FAILURE_REASON" ]
        ''')

    def test_partial_dns_failure_preserves_old_routes(self):
        self.route_case(partial=True)

    def test_complete_dns_refresh_removes_stale_routes(self):
        self.route_case(partial=False)

    def test_game_mode_off_keeps_a_sole_wan_default(self):
        source = (ROOT / 'game_mode.sh').read_text()
        start = source.index('        GW=', source.index('# Save the gateway'))
        end = source.index('        if ip link show', start)
        block = source[start:end]
        self.run_shell("""
        WAN_IF=eth0
        HAS_ONE=1; HAS_TEN=0
        ip() {
            case "$*" in
                '-4 route show default dev eth0')
                    [ "$HAS_ONE" -eq 1 ] && echo 'default via 10.0.0.1 dev eth0 metric 1';;
                'route replace default via 10.0.0.1 dev eth0 metric 10') HAS_TEN=1;;
                '-4 route del default dev eth0 metric 1')
                    [ "$HAS_TEN" -eq 1 ] || exit 9
                    HAS_ONE=0;;
                *) exit 8;;
            esac
        }
        """ + block + '[ "$HAS_TEN" -eq 1 ] && [ "$HAS_ONE" -eq 0 ]')

    def test_monitor_distinguishes_http_and_transport_failures(self):
        source = (ROOT / 'monitor_game_network.sh').read_text()
        block = source[source.index('http_summary()'):source.index('write_log()')]
        output = self.run_shell(block + """
        PROBE_URL=https://example.invalid
        curl() { printf '503 0.1'; }
        http_summary eth0
        curl() { printf '000 3.0'; return 28; }
        http_summary eth0
        curl() { printf '204 0.1'; }
        http_summary tun0
        """)
        self.assertEqual(output.splitlines(), ['HTTP_FAIL 503 0.1', 'TRANSPORT_FAIL 000 3.0', 'OK 204 0.1'])

    def route_case(self, partial):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / 'routes'
            state.write_text('192.0.2.1/32\n192.0.2.2/32\n')
            env = dict(os.environ, TEST_DIR=tmp, PARTIAL=str(int(partial)))
            self.run_shell(function('refresh_host_routes') + '''
            WAN_IF=eth0
            timeout() { shift; "$@"; }
            nslookup() {
                case "$1" in
                    first) echo 'Address 1: 192.0.2.3';;
                    second) [ "$PARTIAL" -eq 0 ] || return 1; echo 'Address 1: 192.0.2.4';;
                esac
            }
            ip() {
                case "$*" in
                    '-4 route show default dev eth0') echo 'default via 10.0.0.1 dev eth0 metric 10';;
                    *) echo "$*" >> "$TEST_DIR/commands";;
                esac
            }
            refresh_host_routes 'first second' 127.0.0.1 "$TEST_DIR/routes"
            ''', env)
            routes = state.read_text()
            commands = (Path(tmp) / 'commands').read_text()
            self.assertIn('192.0.2.3/32', routes)
            if partial:
                self.assertIn('192.0.2.2/32', routes)
                self.assertNotIn('route del', commands)
            else:
                self.assertNotIn('192.0.2.2/32', routes)
                self.assertIn('route del 192.0.2.2/32 via 10.0.0.1 dev eth0 metric 1', commands)
            self.assertEqual(list(Path(tmp).glob('routes.*')), [])

    def test_bidirectional_mss_clamping_checked(self):
        defaults = SOURCE[SOURCE.index('WAN_IF='):SOURCE.index('# DNS servers expected')]
        output = self.run_shell(defaults + function('nat_rules_ok') + r"""
        iptables() { printf 'iptables: %s\n' "$*"; return 0; }
        ip6tables() { printf 'ip6tables: %s\n' "$*"; return 0; }
        nat_rules_ok
        """)
        self.assertIn('iptables: -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240', output)
        self.assertIn('ip6tables: -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220', output)

    def test_ensure_nat_and_mss_rules_repaired(self):
        defaults = SOURCE[SOURCE.index('WAN_IF='):SOURCE.index('# DNS servers expected')]
        output = self.run_shell(defaults + function('ensure_nat_and_mss_rules') + r"""
        iptables() { printf 'iptables: %s\n' "$*"; return 0; }
        ip6tables() { printf 'ip6tables: %s\n' "$*"; return 0; }
        ensure_nat_and_mss_rules
        """)
        self.assertIn('iptables: -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240', output)
        self.assertIn('ip6tables: -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220', output)

    def test_forward_accept_rules_checked(self):
        # F03: FORWARD's policy is DROP, so LAN<->tun0 traffic depends on these rules.
        defaults = SOURCE[SOURCE.index('WAN_IF='):SOURCE.index('# DNS servers expected')]
        output = self.run_shell(defaults + function('nat_rules_ok') + r"""
        iptables() { printf 'iptables: %s\n' "$*"; return 0; }
        ip6tables() { printf 'ip6tables: %s\n' "$*"; return 0; }
        nat_rules_ok
        """)
        for tool in ('iptables', 'ip6tables'):
            self.assertIn(tool + ': -C FORWARD -i br-lan -o tun0 -j ACCEPT', output)
            self.assertIn(tool + ': -C FORWARD -i tun0 -o br-lan -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT', output)

    def test_missing_forward_rules_are_reinserted(self):
        defaults = SOURCE[SOURCE.index('WAN_IF='):SOURCE.index('# DNS servers expected')]
        output = self.run_shell(defaults + function('ensure_nat_and_mss_rules') + r"""
        iptables() { case "$*" in '-C FORWARD'*) return 1;; esac; printf 'iptables: %s\n' "$*"; }
        ip6tables() { case "$*" in '-C FORWARD'*) return 1;; esac; printf 'ip6tables: %s\n' "$*"; }
        ensure_nat_and_mss_rules
        """)
        for tool in ('iptables', 'ip6tables'):
            self.assertIn(tool + ': -I FORWARD -i br-lan -o tun0 -j ACCEPT', output)
            self.assertIn(tool + ': -I FORWARD -i tun0 -o br-lan -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT', output)

    def test_preferred_tunnel_routes_are_silent(self):
        output = self.run_shell(function('warn_if_tunnel_not_preferred') + r"""
        TUN_IF=tun0; ROUTE_PROBE_V4=1.1.1.1; ROUTE_PROBE_V6=2606:4700:4700::1111
        log() { printf 'LOG %s\n' "$*"; }
        collect_diagnostics_once() { printf 'DIAG %s\n' "$1"; }
        ip() { echo "$4 dev tun0 src 172.16.0.2 uid 0"; }
        warn_if_tunnel_not_preferred
        """)
        self.assertEqual(output, '')

    def test_missing_ipv6_route_is_reported_not_fatal(self):
        # `ip route get` fails without a route; under set -e that must not abort.
        output = self.run_shell(function('warn_if_tunnel_not_preferred') + r"""
        TUN_IF=tun0; ROUTE_PROBE_V4=1.1.1.1; ROUTE_PROBE_V6=2606:4700:4700::1111
        log() { printf 'LOG %s\n' "$*"; }
        collect_diagnostics_once() { printf 'DIAG %s\n' "$1"; }
        ip() { case "$1" in -6) echo 'RTNETLINK answers: Network is unreachable'; return 2;; esac; echo "$4 dev tun0 uid 0"; }
        warn_if_tunnel_not_preferred
        echo reached
        """)
        self.assertIn('LOG WARNING: public traffic does not prefer tun0', output)
        self.assertIn('DIAG route-preference', output)
        self.assertTrue(output.endswith('reached\n'))

if __name__ == '__main__':
    unittest.main()

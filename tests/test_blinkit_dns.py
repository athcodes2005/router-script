"""Exercise the production updater with fake DNS/routes in a temporary directory."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BlinkitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.hostdir = self.root / 'hosts'
        self.hostdir.mkdir()
        self.hosts = self.hostdir / 'hosts'
        shutil.copy(ROOT / 'refresh_blinkit_dns.sh', self.root)
        shutil.copy(ROOT / 'defaults.sh', self.root)
        self.command('timeout', 'shift; exec "$@"')
        self.command('nslookup', '''
        printf '%s %s\n' "$1" "$2" >> "$TEST_ROOT/queries"
        [ "$DNS_FAIL" = 0 ] || exit 1
        case " ${DNS_FAIL_DOMAINS:-} " in *" $1 "*) exit 1;; esac
        echo 'Address 1: 192.0.2.10'
        echo 'Address 2: 2001:db8::10'
        ''')
        self.command('ip', '''
        case "$*" in
          '-4 route show default dev eth0') echo 'default via 10.0.0.1 dev eth0 metric 10';;
          *) [ "$ROUTE_FAIL" = 0 ] || exit 1
             echo "$*" >> "$TEST_ROOT/routes"
             case "${1:-} ${2:-}" in
               'route replace') snapshot=at-route-time;;
               'route del') snapshot=at-del-time;;
               *) snapshot=other;;
             esac
             test ! -f "$TEST_ROOT/hosts/hosts" || cat "$TEST_ROOT/hosts/hosts" >> "$TEST_ROOT/$snapshot";;
        esac
        ''')
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'],
                        TEST_ROOT=str(self.root), DNS_FAIL='0', ROUTE_FAIL='0',
                        WAN_IF='eth0', BLINKIT_HOSTS_DIR=str(self.hostdir),
                        BLINKIT_IPV4_DOMAINS='api3.blinkit.com jumbo.blinkit.com',
                        BLINKIT_DNS_SERVERS='8.8.8.8 8.8.4.4', DNSMASQ_PID_DIR=str(self.root/'pids'),
                        CAMPUS_ROUTES_FILE=str(self.root/'campus-routes'),
                        DIRECT_PUBLIC_ROUTES_FILE=str(self.root/'public-routes'),
                        GAME_SESSION_ROUTES_FILE=str(self.root/'game-routes'))

    def command(self, name, body):
        path=self.bin/name
        path.write_text('#!/bin/sh\nset -eu\n'+body+'\n')
        path.chmod(0o755)

    def run_update(self):
        return subprocess.run(['sh',str(self.root/'refresh_blinkit_dns.sh')],
                              env=self.env, capture_output=True, text=True)

    def test_legacy_blinkit_api_is_covered_by_all_policy_defaults(self):
        # Every script takes both lists from defaults.sh (A1).
        text = (ROOT / 'defaults.sh').read_text()
        for name in ['BLINKIT_IPV4_DOMAINS=', 'DIRECT_PUBLIC_DOMAINS=']:
            line = next(line for line in text.splitlines() if line.startswith(name))
            self.assertIn('api2.grofers.com', line, name)
        self.env['BLINKIT_IPV4_DOMAINS'] += ' api2.grofers.com'
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('192.0.2.10 api2.grofers.com', self.hosts.read_text())

    def test_publish_ipv4_after_installing_routes(self):
        self.hosts.write_text('192.0.2.1 api3.blinkit.com\n192.0.2.2 jumbo.blinkit.com\n')
        result=self.run_update()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.hosts.read_text(),'192.0.2.10 api3.blinkit.com\n192.0.2.10 jumbo.blinkit.com\n')
        self.assertNotIn('192.0.2.10', (self.root/'at-route-time').read_text())
        self.assertNotIn('127.0.0.1',(self.root/'queries').read_text())

    def test_upstream_failure_reuses_saved_answers(self):
        before='192.0.2.1 api3.blinkit.com\n192.0.2.2 jumbo.blinkit.com\n'
        self.hosts.write_text(before)
        self.env['DNS_FAIL']='1'
        result=self.run_update()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.hosts.read_text(),before)
        self.assertIn('route replace 192.0.2.2/32', (self.root/'routes').read_text())

    def test_route_failure_does_not_publish_new_answers(self):
        self.hosts.write_text('192.0.2.1 api3.blinkit.com\n')
        self.env['ROUTE_FAIL']='1'
        self.assertNotEqual(self.run_update().returncode,0)
        self.assertEqual(self.hosts.read_text(),'192.0.2.1 api3.blinkit.com\n')

    def test_no_dns_and_no_saved_record_does_not_publish(self):
        self.env['DNS_FAIL']='1'
        self.assertNotEqual(self.run_update().returncode,0)
        self.assertFalse(self.hosts.exists())

    def test_unchanged_answers_do_not_rewrite_hosts(self):
        self.assertEqual(self.run_update().returncode,0)
        timestamp=self.hosts.stat().st_mtime_ns
        self.assertEqual(self.run_update().returncode,0)
        self.assertEqual(self.hosts.stat().st_mtime_ns,timestamp)

    # F12: no other refresher runs while WARP is down or game mode is on, so
    # the replaced set's routes are this script's to remove, unless another
    # refresher still lists them (it removes those itself).
    def test_replaced_records_lose_routes_no_refresher_lists(self):
        self.hosts.write_text('192.0.2.1 api3.blinkit.com\n192.0.2.2 jumbo.blinkit.com\n')
        (self.root/'public-routes').write_text('192.0.2.2/32\n')
        result=self.run_update()
        self.assertEqual(result.returncode,0,result.stderr)
        routes=(self.root/'routes').read_text()
        self.assertIn('route del 192.0.2.1/32 via 10.0.0.1 dev eth0 metric 1',routes)
        self.assertNotIn('route del 192.0.2.2/32',routes)
        self.assertNotIn('route del 192.0.2.10/32',routes)
        self.assertIn('Blinkit DNS: replaced-address routes removed: 1, left to another refresher: 1.',result.stdout)
        # Unpublished first, so no client is handed an address without its route.
        self.assertNotIn('192.0.2.1 ',(self.root/'at-del-time').read_text())

    def test_unchanged_records_remove_no_routes(self):
        self.hosts.write_text('192.0.2.10 api3.blinkit.com\n192.0.2.10 jumbo.blinkit.com\n')
        self.assertEqual(self.run_update().returncode,0)
        self.assertNotIn('route del',(self.root/'routes').read_text())

    # F12: a run that stops early must not leave routes for answers it never publishes.
    def test_run_that_cannot_publish_installs_no_routes(self):
        self.hosts.write_text('192.0.2.1 api3.blinkit.com\n')  # jumbo has no saved record
        self.env['DNS_FAIL_DOMAINS']='jumbo.blinkit.com'
        self.assertNotEqual(self.run_update().returncode,0)
        self.assertEqual(self.hosts.read_text(),'192.0.2.1 api3.blinkit.com\n')
        self.assertFalse((self.root/'routes').exists())

    # F13: each change HUPs dnsmasq, which also clears its cache; log the rate.
    def test_each_change_is_logged_once_with_a_timestamp(self):
        dnsmasq=subprocess.Popen(['sleep','30'])
        self.addCleanup(dnsmasq.kill)
        (self.root/'pids').mkdir()
        (self.root/'pids'/'dnsmasq.cfg01411c.pid').write_text('%d\n' % dnsmasq.pid)
        changed=self.run_update()
        self.assertRegex(changed.stdout,
                         r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d - Blinkit DNS: records changed \(2 entries\); '
                         r'dnsmasq PIDs reloaded: 1 \(a reload clears the cache\)\.\n$')
        self.assertEqual(dnsmasq.wait(timeout=5),-signal.SIGHUP)
        unchanged=self.run_update()
        self.assertEqual(unchanged.stdout+unchanged.stderr,'')

    # F50: OpenWrt's dnsmasq keeps its PID file in /var/run/dnsmasq/. The signal
    # never reached it there, so dnsmasq kept serving the replaced addresses.
    def test_dnsmasq_is_signalled_through_its_openwrt_pid_file(self):
        dnsmasq=subprocess.Popen(['sleep','30'])
        self.addCleanup(dnsmasq.kill)
        (self.root/'pids'/'dnsmasq').mkdir(parents=True)
        (self.root/'pids'/'dnsmasq'/'dnsmasq.cfg01411c.pid').write_text('%d\n' % dnsmasq.pid)
        changed=self.run_update()
        self.assertIn('dnsmasq PIDs reloaded: 1 ',changed.stdout)
        self.assertEqual(dnsmasq.wait(timeout=5),-signal.SIGHUP)

if __name__ == '__main__':
    unittest.main()

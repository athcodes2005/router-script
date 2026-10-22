"""F38: fw3 restart and flush remove every rule router-script added; a hook restores them."""
import os
import signal
import subprocess
import time
import unittest

from sandbox import Sandbox, SHELL

# How fw3 runs a script include (firewall3 includes.c): sourced, waited for.
FW3_TEMPLATE = 'config() { echo "You cannot use UCI in firewall includes!" >&2; exit 1; }; . %s'
TOOLS = ('iptables', 'ip6tables')


class FirewallHookTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)

    def rules(self, tool):
        return sorted((self.box.state / (tool + '.rules')).read_text().splitlines())

    def flush_firewall(self):
        """What `fw3 restart` and `fw3 flush` do: every chain flushed, every user chain deleted."""
        for tool in TOOLS:
            for kind in ('rules', 'chains'):
                (self.box.state / ('%s.%s' % (tool, kind))).write_text('')

    def run_hook(self):
        """Source the hook as fw3 does, with fw3's output pipes; return how long fw3 waited."""
        started = time.monotonic()
        result = subprocess.run([SHELL, '-c', FW3_TEMPLATE % (self.box.proj / 'firewall_hook.sh')],
                                env=self.box.env(), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return time.monotonic() - started

    def wait_for(self, text):
        deadline = time.monotonic() + 60
        while text not in self.box.log('ensure'):
            self.assertLess(time.monotonic(), deadline, 'never logged: ' + text)
            time.sleep(0.2)

    def test_a_flushed_firewall_is_restored_without_waiting_for_cron(self):
        before = {tool: self.rules(tool) for tool in TOOLS}
        chains = (self.box.state / 'iptables.chains').read_text()
        self.assertTrue(chains)
        self.flush_firewall()
        self.run_hook()
        self.wait_for('Health check passed.')
        log = self.box.log('ensure')
        self.assertIn('Starting health check: the firewall was rebuilt.', log)
        self.assertIn('Reinstalled missing tunnel NAT, MSS or LAN forwarding rules in place.', log)
        for tool in TOOLS:
            self.assertEqual(self.rules(tool), before[tool], tool)
        self.assertEqual((self.box.state / 'iptables.chains').read_text(), chains)
        self.assertNotIn('Restarting tunnel', log)

    def test_fw3_does_not_wait_for_the_health_check(self):
        # A health check that blocks; it must neither delay fw3 nor hold its pipes.
        (self.box.proj / 'ensure_network.sh').write_text(
            'echo $$ > "$SIM_STATE/check_pid"\nexec /bin/sleep 30\n')

        def stop_check():
            pid_file = self.box.state / 'check_pid'
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.addCleanup(stop_check)
        self.assertLess(self.run_hook(), 10)
        deadline = time.monotonic() + 30
        while not (self.box.state / 'check_pid').exists():
            self.assertLess(time.monotonic(), deadline, 'the hook never started a health check')
            time.sleep(0.1)

    def test_nothing_runs_without_a_warp_client(self):
        self.box.flag('warp_down')
        self.run_hook()
        time.sleep(1)
        self.assertEqual(self.box.log('ensure'), '')

    def test_an_unregistered_hook_does_nothing(self):
        self.box.flag('firewall_hook_missing')
        self.run_hook()
        time.sleep(1)
        self.assertEqual(self.box.log('ensure'), '')

    def test_installer_registers_the_include_for_reloads_too(self):
        result = self.box.run('install_firewall_hook.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.box.calls()
        for call in ('uci set firewall.router_script=include',
                     'uci set firewall.router_script.type=script',
                     'uci set firewall.router_script.path=%s/firewall_hook.sh' % self.box.proj,
                     'uci set firewall.router_script.reload=1',
                     'uci commit firewall'):
            self.assertIn(call, calls)
        self.assertLess(calls.index('uci set firewall.router_script.reload=1'), calls.index('uci commit firewall'))

    def test_bootstrap_registers_the_hook(self):
        text = (self.box.proj / 'bootstrap_router.sh').read_text()
        self.assertIn('./install_firewall_hook.sh', text)


if __name__ == '__main__':
    unittest.main()

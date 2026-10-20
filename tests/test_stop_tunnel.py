"""stop_tunnel.sh teardown of the legacy split-routing state."""
import unittest

from sandbox import Sandbox, SHELL


class StopTunnelTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        (self.box.proj / 'blocked_sites.txt').write_text(
            '# legacy blocklist\n   # indented comment\n\n  198.51.100.7/32  \n203.0.113.5/32\r\n')
        (self.box.proj / 'warp_clients.txt').write_text('# clients\n\t192.168.8.50\n')
        target = (self.box.bin / 'tr').resolve()
        (self.box.bin / 'tr').unlink()
        (self.box.bin / 'tr').write_text('#!%s\nprintf "tr\\n" >> "$SIM_LOG"\nexec %s "$@"\n' % (SHELL, target))
        (self.box.bin / 'tr').chmod(0o755)

    def test_legacy_entries_are_removed_and_comments_skipped(self):
        self.assertEqual(self.box.run('stop_tunnel.sh').returncode, 0)
        calls = self.box.calls()
        self.assertIn('ip route del 198.51.100.7/32 dev tun0', calls)
        self.assertIn('ip route del 203.0.113.5/32 dev tun0', calls)
        self.assertIn('ip rule del from 192.168.8.50 table 100', calls)
        self.assertFalse([c for c in calls if c.startswith('ip route del #') or 'indented' in c])

    def test_legacy_cleanup_reads_each_file_once(self):
        # F27: an echo|tr pair ran for every entry; one tr per file is enough.
        self.box.run('stop_tunnel.sh')
        self.assertLessEqual(self.box.count('tr'), 2)


if __name__ == '__main__':
    unittest.main()

"""google_wan_policy.sh check-dns runs on every health tick."""
import unittest

from sandbox import Sandbox, SHELL


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

    def test_complete_ipset_list_passes(self):
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns').returncode, 0)

    def test_missing_domain_is_reported(self):
        self.box.flag('google_ipset_drift')
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns').returncode, 1)

    def test_check_is_a_single_pass(self):
        # F11: a tr|grep pair per domain cost about 165 processes per tick.
        self.count_text_tools()
        self.assertEqual(self.box.run('google_wan_policy.sh', 'check-dns').returncode, 0)
        spawned = [line for line in self.box.calls() if line in ('tr', 'grep', 'awk')]
        self.assertLessEqual(len(spawned), 3, spawned[:5])


if __name__ == '__main__':
    unittest.main()

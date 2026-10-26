"""sync_to_router.sh against a fake router directory.

PATH holds only stub ssh/scp and links to a few harmless tools, so the real ssh
cannot be reached; the stubs run the "remote" commands locally against a
temporary directory. Every file is a dummy: the real .env and config.json are
never read or copied.
"""
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

from sandbox import SHELL

ROOT = Path(__file__).resolve().parents[1]
TARGET = 'root@sync-test.invalid'
TOOLS = ['awk', 'basename', 'cat', 'chmod', 'cp', 'date', 'df', 'dirname', 'grep', 'ls', 'mkdir', 'mktemp', 'mv',
         'rm', 'rmdir', 'sleep', 'stat', 'tail']
LOCAL_CONFIG = '{"dummy": "local-registration"}\n'

SSH = r'''while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done
[ "$1" = "$EXPECTED_TARGET" ] || { echo "unexpected ssh target: $1" >&2; exit 255; }
shift
printf 'ssh %s\n' "$*" >> "$CALLS"
case "$*" in
  *promote_staged.sh*)
    if [ -n "${DROP_CONNECTION:-}" ]; then
      # The connection drops just after the promotion starts: its output goes
      # nowhere, and ssh reports the failure.
      { /bin/sleep 0.3; PATH="$RBIN:$PATH" sh -c "$*"; } | true
      exit 255
    fi ;;
esac
PATH="$RBIN:$PATH" exec sh -c "$*"
'''
SCP = r'''legacy=
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -q) shift ;; -O) legacy=1; shift ;; *) break ;; esac; done
# F51: the router has no sftp-server, which OpenSSH 9+ scp uses unless given -O.
[ -n "$legacy" ] || { echo 'sh: /usr/libexec/sftp-server: not found' >&2; exit 255; }
case "$2" in
  "$EXPECTED_TARGET":*)
    printf 'scp %s\n' "${1##*/}" >> "$CALLS"
    cp "$1" "${2#"$EXPECTED_TARGET":}" || exit 1
    # A transfer that went wrong without failing.
    [ "${1##*/}" != "${CORRUPT_FILE:-}" ] || printf 'x' >> "${2#"$EXPECTED_TARGET":}" ;;
  *)
    case "$1" in "$EXPECTED_TARGET":*) ;; *) echo "unexpected scp target: $2" >&2; exit 1 ;; esac
    printf 'scp from %s\n' "${1##*/}" >> "$CALLS"
    # The remote side expands the pattern.
    cp ${1#"$EXPECTED_TARGET":} "$2" || exit 1 ;;
esac
'''


def write_exec(path, body):
    path.write_text('#!%s\n%s' % (SHELL, body))
    path.chmod(0o755)


class SyncTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.local, self.router, bin_dir, rbin = (base / n for n in ('local', 'router', 'bin', 'rbin'))
        for path in (self.local, self.router, bin_dir, rbin):
            path.mkdir()
        self.calls = base / 'calls'
        self.calls.write_text('')
        for name in ('sync_to_router.sh', 'lock.sh', 'promote_staged.sh', 'sync_from_router.sh',
                     'download_emergency_diagnostics.sh'):
            shutil.copy(ROOT / name, self.local)
        files = {'usque-rs': 'binary\n', 'usque-rs-upstream-v0.1.0': 'mac v0.1.0\n',
                 'usque-rs.prev': 'mac prev\n',
                 'config.json': LOCAL_CONFIG, '.env': 'DUMMY=1\n', 'blocked_sites.txt': '# none\n',
                 'paths.sh': '# dummy\n'}
        for name, text in files.items():
            (self.local / name).write_text(text)
        for name in ('config.json', 'blocked_sites.txt'):
            (self.router / name).write_text(files[name])

        for name in TOOLS:
            (bin_dir / name).symlink_to(shutil.which(name))
        (bin_dir / 'sh').symlink_to(SHELL)
        # Prefer shasum locally, as on macOS releases without sha256sum.
        local_hash = shutil.which('shasum') or shutil.which('sha256sum')
        (bin_dir / Path(local_hash).name).symlink_to(local_hash)
        write_exec(bin_dir / 'ssh', SSH)
        write_exec(bin_dir / 'scp', SCP)
        # The router side: BusyBox sha256sum, no tunnel running, and a recorded sync.
        if shutil.which('sha256sum'):
            (rbin / 'sha256sum').symlink_to(shutil.which('sha256sum'))
        else:
            write_exec(rbin / 'sha256sum', 'exec shasum -a 256 "$@"\n')
        write_exec(rbin / 'pidof', 'exit 1\n')
        # At sync time, also record who holds the maintenance lock, and whether it is alive.
        write_exec(rbin / 'sync', 'printf "sync\\n" >> "$CALLS"\nls -A "$ROUTER_SCRIPT_DIR" > "$CALLS.at-sync"\n'
                   'cp "$ROUTER_SCRIPT_DIR/.ensure_network.lock/owner" "$CALLS.owner"\n'
                   'read -r P _ < "$CALLS.owner" && kill -0 "$P" && echo alive >> "$CALLS.owner"\nexit 0\n')

        self.env = {'PATH': str(bin_dir), 'HOME': str(base), 'CALLS': str(self.calls), 'RBIN': str(rbin),
                    'EXPECTED_TARGET': TARGET, 'ROUTER_SSH_TARGET': TARGET,
                    'ROUTER_SCRIPT_DIR': str(self.router)}
        self.assertEqual(shutil.which('ssh', path=self.env['PATH']), str(bin_dir / 'ssh'))
        self.assertEqual(shutil.which('scp', path=self.env['PATH']), str(bin_dir / 'scp'))

    def sync(self, *args):
        return subprocess.run([SHELL, str(self.local / 'sync_to_router.sh'), *args], env=self.env,
                              capture_output=True, text=True, timeout=120)

    def mode(self, name):
        return stat.S_IMODE((self.router / name).stat().st_mode)

    def test_every_script_that_runs_on_the_router_is_deployed(self):
        # A script missing from FILES fails on the router as soon as another one uses it.
        files = re.search(r'^FILES="([^"]*)"', (ROOT / 'sync_to_router.sh').read_text(), re.M).group(1).split()
        mac_only = {'sync_to_router.sh', 'sync_from_router.sh'}
        missing = sorted(p.name for p in ROOT.glob('*.sh') if p.name not in mac_only and p.name not in files)
        self.assertEqual(missing, [])

    def test_git_deploy_list_matches_sync_list(self):
        # B4: update_from_git.sh keeps its own DEPLOY_FILES. The two lists must agree, in the same
        # order (helpers first), except for the files only the Mac holds: secrets and local config
        # are never fetched from git.
        def names(script, var):
            return re.search(r'^%s="([^"]*)"' % var, (ROOT / script).read_text(), re.M).group(1).split()
        mac_only = ['config.json', '.env', 'blocked_sites.txt']
        sync_list = names('sync_to_router.sh', 'FILES')
        deploy_list = names('update_from_git.sh', 'DEPLOY_FILES')
        self.assertEqual(len(set(sync_list)), len(sync_list), 'duplicate in sync list')
        self.assertEqual(len(set(deploy_list)), len(deploy_list), 'duplicate in deploy list')
        self.assertEqual([f for f in sync_list if f not in mac_only], deploy_list)
        self.assertEqual(sorted(set(sync_list) - set(deploy_list)), sorted(mac_only))

    def test_rollback_slot_is_router_local_and_never_shipped(self):
        # B3: the slot holds the router's previous binary; the Mac copy must not replace it.
        (self.router / 'usque-rs.prev').write_text('router previous\n')
        (self.router / 'usque-rs-upstream-v0.1.0').write_text('router legacy\n')
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.router / 'usque-rs.prev').read_text(), 'router previous\n')
        self.assertEqual((self.router / 'usque-rs-upstream-v0.1.0').read_text(), 'router legacy\n')
        sync_files = re.search(r'^FILES="([^"]*)"', (ROOT / 'sync_to_router.sh').read_text(), re.M).group(1).split()
        self.assertNotIn('usque-rs.prev', sync_files)
        self.assertNotIn('usque-rs-upstream-v0.1.0', sync_files)
        self.assertEqual(self.mode('usque-rs'), 0o755)
        self.assertEqual(self.mode('.env'), 0o600)
        self.assertEqual(self.mode('config.json'), 0o600)

    def test_promotion_is_flushed_to_storage(self):
        # F23: a power cut seconds after a deploy could leave zero-length files.
        self.assertEqual(self.sync().returncode, 0)
        self.assertIn('sync', self.calls.read_text().splitlines())
        at_sync = Path(str(self.calls) + '.at-sync').read_text().split()
        self.assertIn('usque-rs', at_sync)
        self.assertFalse([name for name in at_sync if name.startswith('.sync-stage')])

    # F40: the promotion holds the lock with a live owner, so a health check
    # never takes it over by age, however slow the staging was.
    def test_the_promotion_owns_the_maintenance_lock(self):
        self.assertEqual(self.sync().returncode, 0)
        owner = Path(str(self.calls) + '.owner').read_text().split()
        self.assertEqual(owner[3], 'sync_to_router.sh')
        self.assertEqual(owner[-1], 'alive')
        self.assertFalse((self.router / '.ensure_network.lock').exists())

    def test_nothing_is_promoted_when_a_staged_file_is_corrupt(self):
        (self.router / 'usque-rs').write_text('old binary\n')
        self.env['CORRUPT_FILE'] = 'paths.sh'
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('the staged files do not match what was sent; nothing was promoted', result.stdout)
        self.assertEqual((self.router / 'usque-rs').read_text(), 'old binary\n')
        self.assertFalse((self.router / 'paths.sh').exists())
        self.assertFalse([p.name for p in self.router.iterdir() if p.name.startswith('.sync-stage')])

    def test_a_busy_lock_stops_the_promotion(self):
        lock = self.router / '.ensure_network.lock'
        lock.mkdir()
        # lock.sh ages the owner by /proc/uptime; Linux has one, macOS does not.
        try:
            since = int(float(Path('/proc/uptime').read_text().split()[0]))
        except (OSError, ValueError, IndexError):
            since = 0
        (lock / 'owner').write_text('%d 0 %d game_mode.sh\n' % (os.getpid(), since))
        (self.router / 'usque-rs').write_text('old binary\n')
        self.env['SYNC_LOCK_WAIT'] = '1'
        result = self.sync()
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertIn('game_mode.sh (PID %d) holds the maintenance lock; nothing was promoted.' % os.getpid(),
                      result.stdout)
        self.assertEqual((self.router / 'usque-rs').read_text(), 'old binary\n')
        self.assertTrue((lock / 'owner').exists())

    def test_a_dropped_connection_does_not_stop_the_promotion_halfway(self):
        self.env['DROP_CONNECTION'] = '1'
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        for name in ('usque-rs', 'paths.sh', 'lock.sh', 'promote_staged.sh'):
            self.assertTrue((self.router / name).exists(), name)
        self.assertEqual((self.router / 'usque-rs').read_text(), 'binary\n')
        self.assertEqual(self.mode('usque-rs'), 0o755)
        self.assertIn('sync', self.calls.read_text().splitlines())
        self.assertFalse((self.router / '.ensure_network.lock').exists())

    def test_registration_rotated_on_the_router_is_not_overwritten(self):
        # F23: rotate_tunnel_ip.sh registers a new identity on the router.
        rotated = '{"dummy": "rotated-on-router"}\n'
        (self.router / 'config.json').write_text(rotated)
        result = self.sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn('config.json differs', result.stderr)
        self.assertIn('sync_from_router.sh', result.stderr)
        self.assertEqual((self.router / 'config.json').read_text(), rotated)
        self.assertNotIn('scp', self.calls.read_text())
        for text in (rotated, LOCAL_CONFIG):
            self.assertNotIn(text.strip(), result.stdout + result.stderr)

    def test_force_overwrites_a_rotated_registration(self):
        (self.router / 'config.json').write_text('{"dummy": "rotated-on-router"}\n')
        result = self.sync('--force')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.router / 'config.json').read_text(), LOCAL_CONFIG)

    def test_first_deploy_without_a_router_registration_proceeds(self):
        (self.router / 'config.json').unlink()
        self.assertEqual(self.sync().returncode, 0)
        self.assertEqual((self.router / 'config.json').read_text(), LOCAL_CONFIG)

    def run_script(self, name):
        return subprocess.run([SHELL, str(self.local / name)], env=self.env,
                              capture_output=True, text=True, timeout=120)

    # F51: the Mac's scp speaks SFTP unless given -O, and the router has no
    # sftp-server, so every pull failed (sync_to_router.sh is covered above).
    def test_pulling_router_state_uses_the_legacy_scp_protocol(self):
        router_config = '{"endpoint_v4": "dummy", "private_key": "dummy"}\n'
        (self.router / 'config.json').write_text(router_config)
        (self.router / 'blocked_sites.txt').write_text('# edited on the router\n')
        (self.router / 'logs').mkdir()
        (self.router / 'logs' / 'ensure.log').write_text('dummy log\n')
        result = self.run_script('sync_from_router.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'config.json').read_text(), router_config)
        self.assertEqual((self.local / 'blocked_sites.txt').read_text(), '# edited on the router\n')
        self.assertEqual((self.local / 'logs' / 'ensure.log').read_text(), 'dummy log\n')

    def test_an_emergency_snapshot_downloads_with_the_legacy_scp_protocol(self):
        shutil.copy(ROOT / 'paths.sh', self.local)  # the real one sets DIAGNOSTICS_DIR
        write_exec(self.router / 'collect_diagnostics.sh',
                   'mkdir -p diagnostics\nf="$PWD/diagnostics/emergency_20261025_000000_1.log"\n'
                   'echo snapshot > "$f"\necho "$f"\n')
        result = self.run_script('download_emergency_diagnostics.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        snapshot = self.local / 'diagnostics' / 'emergency_20261025_000000_1.log'
        self.assertEqual(snapshot.read_text(), 'snapshot\n')


if __name__ == '__main__':
    unittest.main()

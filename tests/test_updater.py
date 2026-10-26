"""update_from_git.sh: pull deploy branch, gate on CI check-runs, promote and rollback on health failure."""
import json
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from sandbox import Sandbox, SHELL

ROOT = Path(__file__).resolve().parents[1]
SHA = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        # Provide tar (GNU tar execs gzip), gzip and find in the sandbox bin.
        for tool in ('tar', 'gzip', 'find'):
            if not (self.box.bin / tool).exists():
                (self.box.bin / tool).symlink_to(shutil.which(tool))
        self.api = self.box.base / 'api'
        self.api.mkdir()
        # Stub curl for GitHub API requests.
        curl_body = r'''#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -K) cat > "$SIM_STATE/auth_stdin"; shift 2 ;;
    -H|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  */commits/deploy) cp "$API_DIR/commit.json" "$out" ;;
  */check-runs) cp "$API_DIR/checks.json" "$out" ;;
  */tarball/*) cp "$API_DIR/repo.tar.gz" "$out" ;;
  *) exit 22 ;;
esac
'''
        (self.box.bin / 'curl').write_text(curl_body)
        (self.box.bin / 'curl').chmod(0o755)
        # Real jsonfilter isn't on macOS; stub the three expressions update_from_git.sh uses.
        jf_body = r'''#!/bin/sh
file=; expr=
while [ $# -gt 0 ]; do
  case "$1" in
    -i) file=$2; shift 2 ;;
    -e) expr=$2; shift 2 ;;
    *) shift ;;
  esac
done
python3 - "$file" "$expr" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
expr = sys.argv[2]
if expr == '@.sha':
    print(data.get('sha', ''))
elif expr == '@.total_count':
    print(data.get('total_count', 0))
elif expr == '@.check_runs[*].conclusion':
    for r in data.get('check_runs', []):
        print(r.get('conclusion') or '')
elif expr == '@.check_runs[*].status':
    for r in data.get('check_runs', []):
        print(r.get('status') or '')
PY
'''
        (self.box.bin / 'jsonfilter').write_text(jf_body)
        (self.box.bin / 'jsonfilter').chmod(0o755)
        if not (self.box.bin / 'python3').exists():
            (self.box.bin / 'python3').symlink_to(shutil.which('python3'))
        # Real sha256sum or shasum wrapper so sha256sum -c .manifest works in promote_staged.sh.
        sha_body = r'''#!/bin/sh
if [ "${1:-}" = "-c" ]; then
  shift
  while read -r h f; do
    [ -n "$h" ] || continue
    actual="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f")"
    [ "$actual" = "$h" ] || exit 1
  done < "$1"
  exit 0
fi
python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), " ", sys.argv[1])' "$1"
'''
        (self.box.bin / 'sha256sum').write_text(sha_body)
        (self.box.bin / 'sha256sum').chmod(0o755)

        (self.api / 'commit.json').write_text(json.dumps({'sha': SHA}))
        (self.api / 'checks.json').write_text(json.dumps({
            'total_count': 2,
            'check_runs': [
                {'status': 'completed', 'conclusion': 'success'},
                {'status': 'completed', 'conclusion': 'success'},
            ],
        }))

    def make_tarball(self, healthy=True):
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp) / ('router-script-' + SHA[:7])
            pkg.mkdir()
            for f in self.box.proj.iterdir():
                if f.is_file():
                    shutil.copy(f, pkg / f.name)
            (pkg / 'README.md').write_text('# Updated README\n')
            if healthy:
                (pkg / 'ensure_network.sh').write_text('#!/bin/sh\necho "updated ensure ok"\nexit 0\n')
            else:
                (pkg / 'ensure_network.sh').write_text('#!/bin/sh\necho "updated ensure failed"\nexit 1\n')
            (pkg / 'ensure_network.sh').chmod(0o755)
            with tarfile.open(self.api / 'repo.tar.gz', 'w:gz') as tar:
                tar.add(pkg, arcname=pkg.name)

    def run_updater(self, **env):
        return self.box.run('update_from_git.sh', GITHUB_REPO='owner/router-script',
                            GITHUB_TOKEN='ghp_testtoken123', AUTO_FETCH_USQUE='0',
                            API_DIR=str(self.api), **env)

    def test_unconfigured_repo_is_a_clean_noop(self):
        res = self.box.run('update_from_git.sh', AUTO_FETCH_USQUE='0')
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.box.log('maintenance'), '')

    def test_passing_ci_promotes_and_records_commit_without_exposing_token(self):
        self.make_tarball(healthy=True)
        (self.box.proj / 'README.md').write_text('# Old README\n')
        res = self.run_updater()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Updated README\n')
        self.assertIn('Authorization: Bearer ghp_testtoken123', (self.box.state / 'auth_stdin').read_text())
        self.assertIn('Update to %s succeeded and passed the health check.' % SHA, self.box.log('maintenance'))

    def test_failed_ci_check_run_skips_update(self):
        self.make_tarball(healthy=True)
        (self.box.proj / 'README.md').write_text('# Old README\n')
        (self.api / 'checks.json').write_text(json.dumps({
            'total_count': 2,
            'check_runs': [
                {'status': 'completed', 'conclusion': 'success'},
                {'status': 'completed', 'conclusion': 'failure'},
            ],
        }))
        res = self.run_updater()
        self.assertEqual(res.returncode, 0)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Old README\n')
        self.assertFalse((self.box.proj / '.deployed_commit').exists())
        self.assertIn("CI check-run concluded 'failure'", self.box.log('maintenance'))

    def test_failed_health_gate_rolls_back_to_previous_files(self):
        (self.box.proj / 'README.md').write_text('# Working README\n')
        (self.box.proj / 'ensure_network.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.box.proj / 'ensure_network.sh').chmod(0o755)
        self.make_tarball(healthy=False)
        res = self.run_updater()
        self.assertEqual(res.returncode, 1)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Working README\n')
        self.assertEqual((self.box.proj / 'ensure_network.sh').read_text(), '#!/bin/sh\nexit 0\n')
        self.assertFalse((self.box.proj / '.deployed_commit').exists())
        self.assertIn('rolling back', self.box.log('maintenance'))

    def test_failed_commit_is_recorded_and_not_retried(self):
        # B7: a commit that fails the health gate is rolled back once, not every cron run.
        (self.box.proj / 'README.md').write_text('# Working README\n')
        (self.box.proj / 'ensure_network.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.box.proj / 'ensure_network.sh').chmod(0o755)
        self.make_tarball(healthy=False)
        self.assertEqual(self.run_updater().returncode, 1)
        failed = self.box.proj / '.git_failed_commit'
        self.assertEqual(failed.read_text().strip(), SHA)
        # Even a now-healthy tarball for the same commit is skipped.
        self.make_tarball(healthy=True)
        res = self.run_updater()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn('previously failed its health check', self.box.log('maintenance'))
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Working README\n')
        self.assertFalse((self.box.proj / '.deployed_commit').exists())

    def test_failed_commit_skip_ends_when_file_removed_or_flag_given(self):
        (self.box.proj / 'README.md').write_text('# Working README\n')
        (self.box.proj / '.git_failed_commit').write_text(SHA + '\n')
        self.make_tarball(healthy=True)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Working README\n')
        res = self.box.run('update_from_git.sh', '--retry-failed', GITHUB_REPO='owner/router-script',
                           GITHUB_TOKEN='ghp_testtoken123', AUTO_FETCH_USQUE='0', API_DIR=str(self.api))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Updated README\n')
        self.assertFalse((self.box.proj / '.git_failed_commit').exists())
        # Removing the file by hand also ends the skip.
        (self.box.proj / 'README.md').write_text('# Working README\n')
        (self.box.proj / '.deployed_commit').unlink()
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Updated README\n')

    def test_different_commit_is_not_blocked_by_an_old_failure(self):
        (self.box.proj / '.git_failed_commit').write_text('f' * 40 + '\n')
        self.make_tarball(healthy=True)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)
        self.assertFalse((self.box.proj / '.git_failed_commit').exists())


class UsqueFetchTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        for tool in ('tar', 'gzip', 'python3'):
            if not (self.box.bin / tool).exists():
                (self.box.bin / tool).symlink_to(shutil.which(tool))
        self.rel = self.box.base / 'releases'
        self.rel.mkdir()
        curl_body = r'''#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -K) cat > "$SIM_STATE/usque_auth"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "$url" >> "$SIM_STATE/usque_urls"
case "$url" in
  *.sha256) cp "$REL_DIR/asset.sha256" "$out" ;;
  *.tar.gz) cp "$REL_DIR/asset.tar.gz" "$out" ;;
  *) exit 22 ;;
esac
'''
        (self.box.bin / 'curl').write_text(curl_body)
        (self.box.bin / 'curl').chmod(0o755)
        sha_body = r'''#!/bin/sh
python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), " ", sys.argv[1])' "$1"
'''
        (self.box.bin / 'sha256sum').write_text(sha_body)
        (self.box.bin / 'sha256sum').chmod(0o755)

    def make_release(self, script_body, corrupt_sha=False):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            bin_path = Path(tmp) / 'usque-rs'
            bin_path.write_text(script_body)
            bin_path.chmod(0o755)
            archive = self.rel / 'asset.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(bin_path, arcname='usque-rs')
            digest = '0' * 64 if corrupt_sha else hashlib.sha256(archive.read_bytes()).hexdigest()
            (self.rel / 'asset.sha256').write_text('%s  usque-rs-aarch64-linux-musl.tar.gz\n' % digest)
            return digest

    def test_download_only_fetches_and_verifies_binary(self):
        digest = self.make_release('#!/bin/sh\necho "--congestion-control --ready-file --syslog"\n')
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertTrue((self.box.proj / 'usque-rs').exists())
        self.assertEqual((self.box.proj / '.usque_release_sha').read_text().strip(), digest)

    def fetched_urls(self):
        return (self.box.state / 'usque_urls').read_text().split()

    def test_default_tag_is_pinned_not_latest(self):
        # B1: cron must not follow "latest"; a new release needs a tag bump in a commit.
        self.make_release('#!/bin/sh\necho ok\n')
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for url in self.fetched_urls():
            self.assertIn('/releases/download/v0.2.1/', url)
            self.assertNotIn('/latest/', url)

    def test_explicit_latest_tag_still_follows_latest(self):
        self.make_release('#!/bin/sh\necho ok\n')
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel),
                           USQUE_RELEASE_TAG='latest')
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for url in self.fetched_urls():
            self.assertIn('/releases/latest/download/', url)

    def test_corrupt_archive_sha_is_rejected(self):
        (self.box.proj / 'usque-rs').write_text('#!/bin/sh\necho old\n')
        self.make_release('#!/bin/sh\necho new\n', corrupt_sha=True)
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 1)
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), '#!/bin/sh\necho old\n')
        self.assertIn('SHA-256 mismatch', self.box.log('maintenance'))

    def test_router_install_backs_up_previous_and_rolls_back_on_health_failure(self):
        old_bin = '#!/bin/sh\necho "--congestion-control --ready-file --syslog"\n'
        (self.box.proj / 'usque-rs').write_text(old_bin)
        (self.box.proj / 'usque-rs').chmod(0o755)
        (self.box.proj / 'ensure_network.sh').write_text('#!/bin/sh\nexit 1\n')
        (self.box.proj / 'ensure_network.sh').chmod(0o755)
        self.make_release('#!/bin/sh\necho "--congestion-control --ready-file --syslog --upload-codel"\n')
        res = self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 1)
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), old_bin)
        self.assertEqual((self.box.proj / 'usque-rs.prev').read_text(), old_bin)
        self.assertIn('rolling back to previous binary', self.box.log('maintenance'))

    def test_rollback_falls_back_to_legacy_slot_on_an_older_router(self):
        # B3: a router that only has usque-rs-upstream-v0.1.0 must still roll back.
        legacy = '#!/bin/sh\necho "--syslog legacy"\n'
        self.install_router_case(ensure_ok=False)
        # No current binary, so install makes no usque-rs.prev and only the legacy file can restore one.
        (self.box.proj / 'usque-rs').unlink()
        (self.box.proj / 'usque-rs-upstream-v0.1.0').write_text(legacy)
        self.make_release('#!/bin/sh\necho "--syslog bad"\n')
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 1)
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), legacy)

    def test_update_from_git_does_not_ship_rollback_slots(self):
        deploy = re.search(r'^DEPLOY_FILES="([^"]*)"', (ROOT / 'update_from_git.sh').read_text(), re.M).group(1).split()
        self.assertNotIn('usque-rs.prev', deploy)
        self.assertNotIn('usque-rs-upstream-v0.1.0', deploy)

    def install_router_case(self, ensure_ok):
        old_bin = '#!/bin/sh\necho "--congestion-control --ready-file --syslog"\n'
        (self.box.proj / 'usque-rs').write_text(old_bin)
        (self.box.proj / 'usque-rs').chmod(0o755)
        (self.box.proj / 'ensure_network.sh').write_text('#!/bin/sh\nexit %d\n' % (0 if ensure_ok else 1))
        (self.box.proj / 'ensure_network.sh').chmod(0o755)
        for name in ('tunnel.sh', 'stop_tunnel.sh'):
            (self.box.proj / name).write_text('#!/bin/sh\nexit 0\n')
        return old_bin

    def tarball_downloads(self):
        return sum(1 for u in self.fetched_urls() if u.endswith('.tar.gz'))

    def test_failed_archive_is_recorded_and_not_retried(self):
        # B2: a release that fails the health check is rolled back once, not every cron run.
        old_bin = self.install_router_case(ensure_ok=False)
        digest = self.make_release('#!/bin/sh\necho "--syslog bad"\n')
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 1)
        self.assertEqual((self.box.proj / '.usque_failed_sha').read_text().strip(), digest)
        self.assertEqual(self.tarball_downloads(), 1)
        res = self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.tarball_downloads(), 1)
        self.assertIn('previously failed its health check', self.box.log('maintenance'))
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), old_bin)

    def test_failed_archive_skip_ends_on_new_sha_flag_or_file_removal(self):
        self.install_router_case(ensure_ok=True)
        failed = self.box.proj / '.usque_failed_sha'
        digest = self.make_release('#!/bin/sh\necho "--syslog v2"\n')
        failed.write_text(digest + '\n')
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 0)
        self.assertEqual(self.tarball_downloads(), 0)
        # --retry-failed installs it, and success clears the record.
        res = self.box.run('fetch_usque_rs.sh', '--retry-failed', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.tarball_downloads(), 1)
        self.assertFalse(failed.exists())
        # A different archive is not blocked by an older failure.
        failed.write_text('e' * 64 + '\n')
        self.make_release('#!/bin/sh\necho "--syslog v3"\n')
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 0)
        self.assertEqual(self.tarball_downloads(), 2)
        self.assertFalse(failed.exists())
        # Removing the file by hand ends the skip too.
        digest = self.make_release('#!/bin/sh\necho "--syslog v4"\n')
        failed.write_text(digest + '\n')
        failed.unlink()
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 0)
        self.assertEqual(self.tarball_downloads(), 3)


if __name__ == '__main__':
    unittest.main()

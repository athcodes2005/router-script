"""update_from_git.sh: pull the deploy branch without the GitHub API, promote and roll back on health failure."""
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
OTHER_SHA = '0f' * 20


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        # Provide tar (GNU tar execs gzip), gzip and find in the sandbox bin.
        for tool in ('tar', 'gzip', 'find'):
            if not (self.box.bin / tool).exists():
                (self.box.bin / tool).symlink_to(shutil.which(tool))
        self.api = self.box.base / 'api'
        self.api.mkdir()
        # Stub curl for the two github.com requests.
        curl_body = r"""#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -K) cat > "$SIM_STATE/auth_stdin"; shift 2 ;;
    -H) echo "$2" >> "$SIM_STATE/headers"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "$url" >> "$SIM_STATE/urls"
case "$url" in
  */info/refs\?service=git-upload-pack) [ -f "$API_DIR/refs" ] && cp "$API_DIR/refs" "$out" ;;
  */archive/*.tar.gz) cp "$API_DIR/repo.tar.gz" "$out" ;;
  *) exit 22 ;;
esac
"""
        (self.box.bin / 'curl').write_text(curl_body)
        (self.box.bin / 'curl').chmod(0o755)
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

        self.advertise([('HEAD', OTHER_SHA), ('refs/heads/deploy', SHA), ('refs/heads/main', OTHER_SHA)])

    def advertise(self, refs):
        """Write the ref listing GitHub answers a Git client with (pkt-lines, protocol v0)."""
        def pkt(payload):
            return b'%04x' % (len(payload) + 4) + payload
        body = pkt(b'# service=git-upload-pack\n') + b'0000'
        for index, (name, sha) in enumerate(refs):
            capabilities = b'\0multi_ack side-band-64k symref=HEAD:refs/heads/main agent=git/github' if index == 0 else b''
            body += pkt(('%s %s' % (sha, name)).encode() + capabilities + b'\n')
        (self.api / 'refs').write_bytes(body + b'0000')

    def urls(self):
        return (self.box.state / 'urls').read_text().split()

    def make_tarball(self, healthy=True, ensure=None):
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp) / ('router-script-' + SHA)
            pkg.mkdir()
            for f in self.box.proj.iterdir():
                if f.is_file():
                    shutil.copy(f, pkg / f.name)
            (pkg / 'README.md').write_text('# Updated README\n')
            if ensure is not None:
                (pkg / 'ensure_network.sh').write_text(ensure)
            elif healthy:
                (pkg / 'ensure_network.sh').write_text('#!/bin/sh\necho "updated ensure ok"\nexit 0\n')
            else:
                (pkg / 'ensure_network.sh').write_text('#!/bin/sh\necho "updated ensure failed"\nexit 1\n')
            (pkg / 'ensure_network.sh').chmod(0o755)
            with tarfile.open(self.api / 'repo.tar.gz', 'w:gz') as tar:
                tar.add(pkg, arcname=pkg.name)

    def run_updater(self, **env):
        # A token left in .env from the API days must not be sent anywhere.
        return self.box.run('update_from_git.sh', **{
            'GITHUB_REPO': 'owner/router-script', 'GITHUB_TOKEN': 'ghp_testtoken123',
            'AUTO_FETCH_USQUE': '0', 'API_DIR': str(self.api), **env})

    def test_unconfigured_repo_is_a_clean_noop(self):
        res = self.box.run('update_from_git.sh', AUTO_FETCH_USQUE='0')
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.box.log('maintenance'), '')

    def test_the_deploy_head_is_promoted_and_recorded(self):
        self.make_tarball(healthy=True)
        (self.box.proj / 'README.md').write_text('# Old README\n')
        res = self.run_updater()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Updated README\n')
        self.assertIn('Update to %s succeeded and passed the health check.' % SHA, self.box.log('maintenance'))

    # Anonymous API calls are refused once the address the router shares with
    # others has used its 60 an hour, which is most of the time.
    def test_neither_the_api_nor_a_token_is_used(self):
        self.make_tarball(healthy=True)
        (self.box.proj / 'README.md').write_text('# Old README\n')
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual(self.urls(), [
            'https://github.com/owner/router-script.git/info/refs?service=git-upload-pack',
            'https://github.com/owner/router-script/archive/%s.tar.gz' % SHA,
        ])
        self.assertFalse((self.box.state / 'auth_stdin').exists())
        self.assertFalse((self.box.state / 'headers').exists())

    def test_an_installed_deploy_head_costs_one_small_request(self):
        (self.box.proj / '.deployed_commit').write_text(SHA + '\n')
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual(len(self.urls()), 1)
        self.assertEqual(self.box.log('maintenance'), '')

    def test_only_the_configured_branch_is_followed(self):
        self.advertise([('HEAD', OTHER_SHA), ('refs/heads/deploy-old', OTHER_SHA), ('refs/heads/deploy', SHA),
                        ('refs/heads/staging', OTHER_SHA), ('refs/heads/x/deploy', OTHER_SHA),
                        ('refs/tags/deploy', OTHER_SHA)])
        self.make_tarball(healthy=True)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)
        self.assertEqual(self.run_updater(DEPLOY_BRANCH='staging').returncode, 0)
        self.assertIn('/archive/%s.tar.gz' % OTHER_SHA, self.urls()[-1])

    # The first ref follows the flush packet on the same line and carries the capabilities.
    def test_the_branch_is_found_when_it_is_the_first_ref_listed(self):
        self.advertise([('refs/heads/deploy', SHA), ('refs/heads/main', OTHER_SHA)])
        self.make_tarball(healthy=True)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)

    def test_a_listing_without_the_branch_changes_nothing(self):
        self.make_tarball(healthy=True)
        (self.box.proj / 'README.md').write_text('# Old README\n')
        for listing in (None, b'<!DOCTYPE html><html>Sign in to GitHub</html>\n'):
            if listing is None:
                self.advertise([('HEAD', OTHER_SHA), ('refs/heads/main', OTHER_SHA)])
            else:
                (self.api / 'refs').write_bytes(listing)
            res = self.run_updater()
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertEqual((self.box.proj / 'README.md').read_text(), '# Old README\n')
            self.assertFalse((self.box.proj / '.deployed_commit').exists())
        self.assertEqual(self.box.log('maintenance').count('GitHub lists no commit for branch deploy'), 2)
        self.assertFalse([url for url in self.urls() if '/archive/' in url])

    def test_an_unreachable_github_changes_nothing(self):
        (self.api / 'refs').unlink()
        (self.box.proj / 'README.md').write_text('# Old README\n')
        res = self.run_updater()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Old README\n')
        self.assertIn('could not fetch the branches of owner/router-script', self.box.log('maintenance'))

    # The router no longer reads a commit's CI result, so the workflow must be
    # the only thing that moves the branch, and only after the tests.
    def test_ci_moves_the_deploy_branch_only_after_the_tests_on_main(self):
        workflow = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text()
        promote = workflow[workflow.index('\n  promote:'):]
        self.assertIn('needs: shell-and-tests', promote)
        self.assertIn("if: github.event_name == 'push' && github.ref == 'refs/heads/main'", promote)
        self.assertIn('git/refs/heads/deploy', promote)
        self.assertIn('force=false', promote)
        self.assertEqual(workflow.count('contents: write'), 1)
        self.assertIn('contents: write', promote)

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
                           AUTO_FETCH_USQUE='0', API_DIR=str(self.api))
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

    # The gate once passed whenever ensure_network.sh exited 0, which it also
    # did without testing WARP: lock busy, game mode, pending login, cooldown.
    def test_the_health_check_runs_as_a_gate(self):
        self.make_tarball(ensure='#!/bin/sh\nprintf \'%s\\n\' "${ROUTER_SCRIPT_TRIGGER:-}" >> "$SIM_STATE/triggers"\n')
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.state / 'triggers').read_text().split(), ['gate'])

    def test_an_update_the_gate_could_not_test_is_rolled_back_but_not_recorded(self):
        (self.box.proj / 'README.md').write_text('# Working README\n')
        (self.box.proj / 'ensure_network.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.box.proj / 'ensure_network.sh').chmod(0o755)
        self.make_tarball(ensure='#!/bin/sh\nexit 75\n')
        self.assertEqual(self.run_updater().returncode, 1)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Working README\n')
        self.assertFalse((self.box.proj / '.deployed_commit').exists())
        self.assertFalse((self.box.proj / '.git_failed_commit').exists())
        self.assertIn('could not test WARP after promoting %s; rolling back' % SHA, self.box.log('maintenance'))
        # Not recorded as failed, so the next run tries the commit again.
        self.make_tarball(healthy=True)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)

    def test_updates_wait_while_the_gate_could_not_test_warp(self):
        (self.box.proj / 'README.md').write_text('# Old README\n')
        self.make_tarball(healthy=True)
        for marker in ('router-script-game-mode', 'router-script-interactive-login-required'):
            (self.box.tmp / marker).write_text('on\n')
            self.assertEqual(self.run_updater().returncode, 0)
            self.assertEqual((self.box.proj / 'README.md').read_text(), '# Old README\n')
            self.assertFalse((self.box.proj / '.deployed_commit').exists())
            (self.box.tmp / marker).unlink()
        self.assertEqual(self.box.log('maintenance').count('Deferring %s' % SHA), 2)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual((self.box.proj / 'README.md').read_text(), '# Updated README\n')

    # Every promotion used to stop WARP, wiki-only commits included.
    def test_a_commit_that_changes_no_deployed_file_leaves_the_tunnel_running(self):
        stub = '#!/bin/sh\nexit 0\n'
        (self.box.proj / 'ensure_network.sh').write_text(stub)
        (self.box.proj / 'README.md').write_text('# Updated README\n')
        self.make_tarball(ensure=stub)
        res = self.run_updater()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.box.count('killall'), 0)
        self.assertIn('already matches the installed one; the tunnel keeps running', self.box.log('maintenance'))
        self.assertEqual((self.box.proj / '.deployed_commit').read_text().strip(), SHA)
        self.assertFalse([p.name for p in self.box.proj.iterdir() if p.name.startswith('.git-')])

    def test_a_commit_that_changes_a_deployed_file_still_stops_the_tunnel(self):
        (self.box.proj / 'README.md').write_text('# Old README\n')
        self.make_tarball(healthy=True)
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertGreater(self.box.count('killall'), 0)

    # Started outside the lock, the tunnel could be stopped by a health tick
    # that found it half started, and each start then killed the other's client.
    def test_the_tunnel_the_promotion_stopped_restarts_under_the_lock(self):
        running = self.box.state / 'client_running'
        running.write_text('')
        (self.box.bin / 'pidof').write_text(
            '#!/bin/sh\n[ "$1" = usque-rs ] && [ -f "$SIM_STATE/client_running" ] && echo 456\n')
        (self.box.proj / 'stop_tunnel.sh').write_text('#!/bin/sh\nrm -f "$SIM_STATE/client_running"\n')
        (self.box.proj / 'tunnel.sh').write_text(
            '#!/bin/sh\ncat "$(dirname "$0")/.ensure_network.lock/owner" > "$SIM_STATE/tunnel_started_by"\n'
            ': > "$SIM_STATE/client_running"\n')
        self.make_tarball(healthy=True)
        res = self.run_updater()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual((self.box.state / 'tunnel_started_by').read_text().split()[3], 'update_from_git.sh')
        self.assertTrue(running.exists())
        self.assertFalse((self.box.proj / '.ensure_network.lock').exists())


class UsqueFetchTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox.fresh(self)
        # These releases are made up, so the hash pinned in defaults.sh cannot
        # match them: no pin, unless a test sets its own.
        sandbox_env = self.box.env
        self.box.env = lambda **extra: sandbox_env(**{'USQUE_RELEASE_SHA256': '', **extra})
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
            self.assertIn('/releases/download/v0.2.5/', url)
            self.assertNotIn('/latest/', url)

    def test_explicit_latest_tag_still_follows_latest(self):
        self.make_release('#!/bin/sh\necho ok\n')
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel),
                           USQUE_RELEASE_TAG='latest')
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for url in self.fetched_urls():
            self.assertIn('/releases/latest/download/', url)

    # The checksum beside the archive is replaced together with it, so only a
    # hash kept on our side shows that the release still holds what was pinned.
    def test_a_pinned_hash_decides_without_the_published_checksum(self):
        digest = self.make_release('#!/bin/sh\necho "--syslog pinned"\n')
        (self.rel / 'asset.sha256').write_text('%s  replaced-with-the-archive\n' % ('f' * 64))
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel), USQUE_RELEASE_SHA256=digest)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual((self.box.proj / '.usque_release_sha').read_text().strip(), digest)
        self.assertFalse([url for url in self.fetched_urls() if url.endswith('.sha256')])

    def test_an_archive_that_differs_from_the_pinned_hash_is_refused(self):
        (self.box.proj / 'usque-rs').write_text('#!/bin/sh\necho old\n')
        self.make_release('#!/bin/sh\necho "replaced under the same tag"\n')
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel),
                           USQUE_RELEASE_SHA256='a' * 64)
        self.assertEqual(res.returncode, 1)
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), '#!/bin/sh\necho old\n')
        self.assertIn('from the pinned USQUE_RELEASE_SHA256', self.box.log('maintenance'))

    def test_an_installed_pinned_release_needs_no_network(self):
        digest = self.make_release('#!/bin/sh\necho "--syslog pinned"\n')
        (self.box.proj / 'usque-rs').write_text('installed\n')
        (self.box.proj / '.usque_release_sha').write_text(digest + '\n')
        res = self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel), USQUE_RELEASE_SHA256=digest)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertFalse((self.box.state / 'usque_urls').exists())

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

    def test_a_binary_the_gate_could_not_test_is_rolled_back_but_not_recorded(self):
        old_bin = self.install_router_case(ensure_ok=True)
        (self.box.proj / 'ensure_network.sh').write_text(
            '#!/bin/sh\n[ "${ROUTER_SCRIPT_TRIGGER:-}" = gate ] || exit 0\nexit 75\n')
        self.make_release('#!/bin/sh\necho "--syslog new"\n')
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 1)
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), old_bin)
        self.assertFalse((self.box.proj / '.usque_failed_sha').exists())
        self.assertFalse((self.box.proj / '.usque_release_sha').exists())
        self.assertIn('could not test WARP', self.box.log('maintenance'))
        # Not recorded as failed, so the next run downloads and tries it again.
        self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel))
        self.assertEqual(self.tarball_downloads(), 2)

    def test_binary_updates_wait_while_the_gate_could_not_test_warp(self):
        old_bin = self.install_router_case(ensure_ok=True)
        self.make_release('#!/bin/sh\necho "--syslog new"\n')
        (self.box.tmp / 'router-script-game-mode').write_text('on\n')
        self.assertEqual(self.box.run('fetch_usque_rs.sh', REL_DIR=str(self.rel)).returncode, 0)
        self.assertEqual((self.box.proj / 'usque-rs').read_text(), old_bin)
        self.assertEqual(self.tarball_downloads(), 0)
        self.assertIn('Deferring usque-rs release', self.box.log('maintenance'))
        # The Mac's --download-only has no gate and is not held back.
        res = self.box.run('fetch_usque_rs.sh', '--download-only', REL_DIR=str(self.rel))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.tarball_downloads(), 1)

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

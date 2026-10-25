"""update_from_git.sh: pull deploy branch, gate on CI check-runs, promote and rollback on health failure."""
import json
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
        # Provide tar and find in the sandbox bin.
        for tool in ('tar', 'find'):
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
                            GITHUB_TOKEN='ghp_testtoken123', API_DIR=str(self.api), **env)

    def test_unconfigured_repo_is_a_clean_noop(self):
        res = self.box.run('update_from_git.sh')
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


if __name__ == '__main__':
    unittest.main()

"""Portal login must not expose the access token in a process command line."""
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import unittest

from sandbox import Sandbox

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'login.sh').read_text()
FUNCTIONS = ''.join(re.findall(r'^[a-z_]+\(\) \{\n.*?^\}\n', SOURCE, re.M | re.S))
USER = 'u123'
PASS = 'p@ss"w\\rd:x'


class LoginTests(unittest.TestCase):
    def test_token_is_not_passed_in_curl_arguments(self):
        # F05: /proc/<pid>/cmdline is world-readable for the whole request.
        with tempfile.TemporaryDirectory() as tmp:
            script = FUNCTIONS + r'''
            curl() { printf '%s\n' "$@" > "$TMP/argv"; cat > "$TMP/stdin"; printf 'HTTP 200 final=https://internet.iitb.ac.in/login.php'; }
            WAN_IF=eth0; RESOLVE_OPTS=; PORTAL_BASE_URL=https://internet.iitb.ac.in; LOG_FILE="$TMP/login.log"
            token_login
            '''
            result = subprocess.run(['sh', '-eu', '-c', script], text=True, capture_output=True,
                                    env={'PATH': '/usr/bin:/bin', 'TMP': tmp, 'USER': USER, 'PASS': PASS})
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = Path(tmp, 'argv').read_text()
            self.assertNotIn('p@ss', argv)
            self.assertIn('-K', argv.splitlines())
            self.assertEqual(Path(tmp, 'stdin').read_text(), 'user = "u123:p@ss\\"w\\\\rd:x"\n')

    def test_tls_verification_failure_points_at_the_clock(self):
        # F21: a clock months behind makes the portal's valid certificate "not yet valid".
        with tempfile.TemporaryDirectory() as tmp:
            script = FUNCTIONS + r'''
            WAN_IF=eth0; RESOLVE_OPTS=; PORTAL_BASE_URL=https://internet.iitb.ac.in; LOG_FILE="$TMP/login.log"
            curl() { cat > /dev/null; printf 'HTTP 200 final=https://internet.iitb.ac.in/login.php'; }
            token_login
            grep -q 'router clock' "$LOG_FILE" && exit 9
            curl() { cat > /dev/null; echo 'curl: (60) SSL certificate problem: certificate is not yet valid' >&2; return 60; }
            token_login
            '''
            result = subprocess.run(['sh', '-eu', '-c', script], text=True, capture_output=True,
                                    env={'PATH': '/usr/bin:/bin', 'TMP': tmp, 'USER': USER, 'PASS': PASS})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Check the router clock', Path(tmp, 'login.log').read_text())

    @unittest.skipUnless(shutil.which('curl'), 'curl is required')
    def test_real_curl_sends_the_escaped_credentials(self):
        headers = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                headers.append(self.headers.get('Authorization', ''))
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        try:
            script = FUNCTIONS + 'curl_credentials | curl -sS -K - -o /dev/null "http://127.0.0.1:%d/"\n' % server.server_port
            result = subprocess.run(['sh', '-eu', '-c', script], text=True, capture_output=True,
                                    env={'PATH': '/usr/bin:/bin', 'USER': USER, 'PASS': PASS}, timeout=30)
        finally:
            thread.join(timeout=30)
            server.server_close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(headers, ['Basic ' + base64.b64encode((USER + ':' + PASS).encode()).decode()])

    def test_successful_login_flushes_dnsmasq_cache(self):
        box = Sandbox.fresh(self)
        (box.proj / '.env').write_text('USER=u123\nPASS=secret\n')
        box.flag('direct_down')
        curl_path = box.bin / 'curl'
        orig_curl = curl_path.read_text()
        hook = (
            'case "$url" in */login.php) @RM@ -f "$SIM_STATE/direct_down"; code=200;; esac\n'
        ).replace('@RM@', '/bin/rm')
        curl_path.write_text(orig_curl.replace('tc=0.021;', hook + 'tc=0.021;'))
        result = box.run('login.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('First login successful. Internet is active.', box.log('login'))
        self.assertEqual(box.count('killall -HUP dnsmasq'), 1)

    def test_already_active_internet_does_not_flush_dnsmasq_cache(self):
        box = Sandbox.fresh(self)
        (box.proj / '.env').write_text('USER=u123\nPASS=secret\n')
        result = box.run('login.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Internet connection is active.', box.log('login'))
        self.assertEqual(box.count('killall'), 0)


if __name__ == '__main__':
    unittest.main()

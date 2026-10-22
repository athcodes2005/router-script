"""Run copies of the router scripts against stubbed system commands.

Scripts are copied into a temporary directory (never .env, config.json or the
binaries), absolute system paths are rewritten into a fake root, and PATH holds
only logging stubs plus a few harmless real utilities. Nothing can reach real
routes, firewall rules, UCI, cron, services or the network.
"""
import atexit
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# dash is the closest locally available relative of BusyBox ash.
SHELL = shutil.which('dash') or '/bin/sh'
REWRITES = [
    ('/etc/init.d/', '${SYSROOT}/etc/init.d/'),
    ('/etc/dnscrypt-proxy2/', '${SYSROOT}/etc/dnscrypt-proxy2/'),
    ('/etc/router-script/', '${SYSROOT}/etc/router-script/'),
    ('/sys/class/net/', '${SYSROOT}/sys/class/net/'),
    ('"/proc/', '"${SYSROOT}/proc/'),
    ('/var/run', '${SYSROOT}/var/run'),
    ('/tmp/', '${SIMTMP}/'),
]
REAL_TOOLS = ['awk', 'basename', 'cat', 'chmod', 'cmp', 'cp', 'cut', 'date', 'df', 'dirname',
              'grep', 'head', 'ls', 'mkdir', 'mktemp', 'mv', 'rm', 'rmdir', 'sort', 'tail',
              'tee', 'touch', 'tr', 'uniq', 'wc']
DATA_FILES = ['google_domains.txt', 'google_service_ranges.txt', 'blocked_sites.txt', 'warp_clients.txt']

PRELUDE = r'''printf '%s\n' "${0##*/} $*" >> "$SIM_LOG"
flag() { [ -f "$SIM_STATE/$1" ]; }
'''

# Stateful so that `while iptables -C ...; do iptables -D ...; done` terminates.
IPTABLES = r'''f="$SIM_STATE/${0##*/}.rules"; c="$SIM_STATE/${0##*/}.chains"
[ -f "$f" ] || : > "$f"; [ -f "$c" ] || : > "$c"
table=filter
if [ "${1:-}" = -t ]; then table=$2; shift 2; fi
op=${1:-}; chain=${2:-}
if [ $# -ge 2 ]; then shift 2; else shift $#; fi
case "$op" in -I) case "${1:-}" in ''|*[!0-9]*) ;; *) shift ;; esac ;; esac
key="$table $chain $*"
case "$op $chain" in '-I INPUT') flag input_rule_fail && exit 1 ;; esac
case "$op" in
  -C) @GREP@ -Fqx -- "$key" "$f" ;;
  -A) printf '%s\n' "$key" >> "$f" ;;
  -I) { printf '%s\n' "$key"; @CAT@ "$f"; } > "$f.tmp" && @MV@ "$f.tmp" "$f" ;;
  -D) @GREP@ -Fqx -- "$key" "$f" || exit 1
      @AWK@ -v k="$key" '!d && $0 == k { d = 1; next } { print }' "$f" > "$f.tmp" && @MV@ "$f.tmp" "$f" ;;
  -F) @AWK@ -v t="$table" -v ch="$chain" '!($1 == t && $2 == ch)' "$f" > "$f.tmp" && @MV@ "$f.tmp" "$f" ;;
  -N) @GREP@ -Fqx -- "$table $chain" "$c" && exit 1; printf '%s\n' "$table $chain" >> "$c" ;;
  -X) @AWK@ -v k="$table $chain" '$0 != k' "$c" > "$c.tmp" && @MV@ "$c.tmp" "$c" ;;
  -L|-S)
    case "$chain" in
      PREROUTING|INPUT|FORWARD|OUTPUT|POSTROUTING) [ "$op" = -S ] && printf '%s\n' "-P $chain ACCEPT" ;;
      *) @GREP@ -Fqx -- "$table $chain" "$c" || exit 1; [ "$op" = -S ] && printf '%s\n' "-N $chain" ;;
    esac
    if [ "$op" = -S ]; then
      @AWK@ -v t="$table" -v ch="$chain" '$1 == t && $2 == ch { $1 = ""; $2 = ""; sub(/^  /, ""); print "-A " ch " " $0 }' "$f"
    fi ;;
esac
'''

IP = r'''r="$SIM_STATE/ip.rules"
[ -f "$r" ] || printf '0:\tfrom all lookup local\n690:\tfrom all oif tun0 lookup main\n710:\tfrom all fwmark 0x100000/0x100000 lookup 102\n32766:\tfrom all lookup main\n' > "$r"
rule_line() {
  prio=; oif=; mark=; tab=
  while [ $# -gt 0 ]; do
    case "$1" in
      priority|pref) prio=$2; shift 2 ;;
      oif) oif=$2; shift 2 ;;
      fwmark) mark=$2; shift 2 ;;
      table|lookup) tab=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  line="$prio:	from all"
  [ -n "$oif" ] && line="$line oif $oif"
  [ -n "$mark" ] && line="$line fwmark $mark"
  printf '%s lookup %s\n' "$line" "$tab"
}
case "$*" in
  'rule show') @SORT@ -n "$r" ;;
  'rule add '*) shift 2; rule_line "$@" >> "$r" ;;
  'rule del '*) shift 2; l="$(rule_line "$@")"
    @GREP@ -Fqx -- "$l" "$r" || exit 1
    @AWK@ -v k="$l" '!d && $0 == k { d = 1; next } { print }' "$r" > "$r.tmp" && @MV@ "$r.tmp" "$r" ;;
  '-4 route show default dev eth0'|'route show default dev eth0')
    flag wan_down && exit 0
    if flag wan_metric_low; then echo 'default via 10.1.40.250 dev eth0 proto static src 10.1.39.202 metric 3'
    else echo 'default via 10.1.40.250 dev eth0 proto static src 10.1.39.202 metric 10'; fi ;;
  '-4 route show default'|'route show default')
    if flag extra_default; then echo 'default via 192.168.100.1 dev wwan0 proto static metric 3'; fi
    flag warp_down || echo 'default dev tun0 scope link metric 5'
    flag wan_down || echo 'default via 10.1.40.250 dev eth0 proto static src 10.1.39.202 metric 10' ;;
  '-6 route show default') flag warp_down || echo 'default dev tun0 metric 5 pref medium' ;;
  'route get 10.200.1.11')
    if flag campus_route_tun; then echo '10.200.1.11 dev tun0 src 172.16.0.2 uid 0'
    else echo '10.200.1.11 via 10.1.40.250 dev eth0 src 10.1.39.202 uid 0'; fi ;;
  'route replace 10.0.0.0/8 via '*) if flag campus_route_fixable; then @RM@ -f "$SIM_STATE/campus_route_tun"; fi ;;
  'route replace 198.51.100.10/32 '*) if flag host_route_fail; then exit 2; fi ;;
  '-4 route get '*)
    if flag route_bypass; then echo "$4 via 10.1.40.250 dev eth0 src 10.1.39.202 uid 0"
    else echo "$4 dev tun0 src 172.16.0.2 uid 0"; fi ;;
  '-6 route get '*) echo "$4 from :: dev tun0 proto kernel src 2606:4700:110::2 metric 5 pref medium" ;;
  'link show dev tun0') flag warp_down && exit 1; echo '9: tun0: <POINTOPOINT,UP> mtu 1280' ;;
  '-6 addr show dev br-lan') echo '    inet6 fd63:3b28:d1ea::1/64 scope global' ;;
  '-4 addr show dev eth0') echo '    inet 10.1.39.202/19 brd 10.1.63.255 scope global eth0' ;;
  '-4 route show dev eth0 scope link') echo '10.1.32.0/19 proto static scope link metric 10' ;;
esac
'''

UCI = r'''key=; for a in "$@"; do key=$a; done
case "$1 ${2:-}" in '-q get'|'get '*) ;; *) exit 0 ;; esac
case "$key" in
  'dhcp.@dnsmasq[0].strictorder'|'dhcp.@dnsmasq[0].noresolv') echo 1 ;;
  'dhcp.@dnsmasq[0].filter_aaaa') if flag filter_aaaa_on; then echo 1; else echo 0; fi ;;
  'dhcp.@dnsmasq[0].server')
    if flag dns_order_drift; then printf '10.200.1.11 8.8.8.8 8.8.4.4 127.0.0.1#5453'
    else printf '8.8.8.8 8.8.4.4 10.200.1.11 127.0.0.1#5453'; fi
    printf ' /api3.blinkit.com/ /jumbo.blinkit.com/ /api2.grofers.com/'
    for d in internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in; do
      [ "$d" = webmail.iitb.ac.in ] && flag dns_drift && continue
      printf ' /%s/10.200.1.11' "$d"
    done
    flag dns_zone_forward && printf ' /iitb.ac.in/10.200.1.11'
    echo ;;
  'dhcp.@dnsmasq[0].addnhosts') echo "$BLINKIT_HOSTS_DIR" ;;
  'dhcp.@dnsmasq[0].address') echo '/internet.iitb.ac.in/10.201.250.201 /sso.iitb.ac.in/10.200.1.100' ;;
  'dhcp.@dnsmasq[0].ipset')
    if flag google_ipset_drift; then skip=1; else skip=0; fi
    @AWK@ -v skip="$skip" 'NF && $0 !~ /^#/ { if (skip && !dropped) { dropped = 1; next }
      printf "%s/%s/google_dns4,google_dns6", sep, $0; sep = " " } END { print "" }' "$SIM_PROJ/google_domains.txt" ;;
  'dhcp.lan.ra'|'dhcp.lan.dhcpv6') echo server ;;
  'dhcp.lan.ra_slaac') echo 1 ;;
  'dhcp.lan.ra_default') echo 2 ;;
  'network.lan.ip6ifaceid') echo ::1 ;;
  'network.globals.ula_prefix') echo 'fd63:3b28:d1ea::/48' ;;
  wireless.mt798111|wireless.mt798112) flag wifi_sections_missing || echo wifi-device ;;
  firewall.router_script.path) flag firewall_hook_missing && exit 1; echo "$SIM_PROJ/firewall_hook.sh" ;;
  wireless.*.country) echo IN ;;
  wireless.mt798111.htmode) echo HE20 ;;
  wireless.mt798112.htmode) if flag wifi_drift; then echo HE160; else echo HE80; fi ;;
  wireless.*.channel) echo auto ;;
  *) exit 1 ;;
esac
'''

CURL = r'''url=; v6=0; iface=; fmt=; body_to=; prev=
for a in "$@"; do
  case "$a" in -6) v6=1 ;; http://*|https://*) url=$a ;; esac
  [ "$prev" = --interface ] && iface=$a
  [ "$prev" = -w ] && fmt=$a
  [ "$prev" = -o ] && body_to=$a
  prev=$a
done
flag curl_blocks && { : > "$SIM_STATE/blocked"; exec /bin/sleep 30; }
code=204; t=0.050
[ "$iface" = tun0 ] && flag tunnel_slow && t=2.400
case "$url" in */login.php|*/logout.php|*/cdn-cgi/trace) code=200 ;; esac
[ "$iface" = eth0 ] && flag direct_down && code=000
[ "$iface" = tun0 ] && flag warp_down && code=000
case "$url" in http://1.1.1.1/*) flag rtt_fail && code=000 ;; esac
tc=0.021; [ "$code" != 000 ] || tc=0.000  # curl reports no connect time for a failed connection
size=0
# The speed test: each download takes a second, or the request is refused.
case "$code $url" in
  000\ *) ;;
  *'/__down'*) if flag download_refused; then code=403; size=1; else code=200; size=25000000; /bin/sleep 1; fi ;;
esac
case "$url" in *google.com*) [ "$v6" = 1 ] && flag google_v6_rejected && code=000 ;; esac
if [ "$code" != 000 ] && [ -z "$body_to" ]; then
  case "$url" in */cdn-cgi/trace)
    if flag warp_trace_off; then printf 'fl=1\nwarp=off\n'; else printf 'fl=1\nwarp=on\n'; fi ;;
  esac
fi
out=$(printf '%s' "$fmt" | @SED@ -e "s/%{http_code}/$code/g" -e "s|%{url_effective}|$url|g" -e "s/%{time_total}/$t/g" \
  -e "s/%{time_connect}/$tc/g" -e "s/%{speed_upload}/4000000/g" -e "s/%{speed_download}/12500000/g" \
  -e "s/%{size_download}/$size/g")
printf '%b' "$out"
[ "$code" = 000 ] && exit 7
exit 0
'''

STUBS = {
    'sleep': ':',
    'timeout': 'shift; exec "$@"',
    'sha256sum': 'echo "simhash  $1"',
    'pidof': r'''case "$1" in
  usque-rs) flag warp_down && exit 1
    # Absent for one check, as when tunnel.sh must launch a new client.
    if flag client_absent_once; then @RM@ -f "$SIM_STATE/client_absent_once"; exit 1; fi
    @CAT@ "$SIM_STATE/usque_pid" 2>/dev/null || echo 456 ;;
  dnsmasq) flag dnsmasq_down && exit 1; echo 123 ;;
  *) exit 1 ;;
esac''',
    'ubus': '@CAT@ "$SIM_STATE/wireless.json" 2>/dev/null || echo "{}"',
    'jsonfilter': r'''case "$*" in
  *endpoint_v4*) echo 162.159.198.2 ;;
  *.up*) if flag wifi_down; then echo false; else echo true; fi ;;
  *) echo true ;;
esac''',
    'ifstatus': r'''flag wan_down && { echo '{ "up": false }'; exit 0; }
echo '{ "up": true, "ipv4-address": [ { "address": "10.1.39.202", "mask": 19 } ] }' ''',
    'conntrack': r'''echo 'tcp 6 431999 ESTABLISHED src=192.168.8.20 dst=44.252.91.204 sport=50000 dport=9339 src=44.252.91.204 dst=10.1.39.202 sport=9339 dport=50000 [ASSURED] mark=0 use=1' ''',
    'nslookup': r'''case "$1" in -query=*) shift ;; esac
name=$1; server=${2:-127.0.0.1}
flag dns_fail && exit 1
printf 'Server:\t\t%s\nAddress:\t%s#53\n\nName:      %s\n' "$server" "$server" "$name"
case "$name" in
  internet.iitb.ac.in) echo 'Address 1: 10.201.250.201' ;;
  sso.iitb.ac.in) echo 'Address 1: 10.200.1.100' ;;
  api3.blinkit.com|jumbo.blinkit.com|api2.grofers.com)
    # dnsmasq serves these local zones from the Blinkit hosts file only.
    if [ "$server" = 127.0.0.1 ]; then
      @AWK@ -v n="$name" '$2 == n { print "Address " ++i ": " $1 }' "$BLINKIT_HOSTS_DIR/hosts" 2>/dev/null
    else
      echo "Address 1: $(@CAT@ "$SIM_STATE/blinkit_upstream" 2>/dev/null || echo 198.51.100.10)"
    fi ;;
  *) echo 'Address 1: 198.51.100.10'; echo 'Address 2: 2001:db8::10' ;;
esac''',
    'ipset': 'flag ipset_fail && exit 1; :',
    'iptables': IPTABLES,
    'ip6tables': IPTABLES,
    'ip': IP,
    'uci': UCI,
    'curl': CURL,
}
NO_OPS = ['fw3', 'sysctl', 'killall', 'ifup', 'ifdown', 'wifi', 'logread', 'dmesg', 'tc', 'netstat',
          'crontab', 'free', 'uptime', 'uname', 'ps', 'ping', 'du', 'logger']
SERVICES = ['dnsmasq', 'odhcpd', 'dnscrypt-proxy', 'cron', 'firewall']


def _write_exec(path, body):
    path.write_text(body)
    path.chmod(0o755)


class Sandbox:
    """One isolated copy of the project; flags in state/ switch stub behaviour."""

    _template = None

    def __init__(self, base):
        self.base = Path(base)
        self.proj = self.base / 'proj'
        self.bin = self.base / 'bin'
        self.sysroot = self.base / 'sysroot'
        self.tmp = self.base / 'tmp'
        self.state = self.base / 'state'
        self.calls_file = self.state / 'calls.log'

    @classmethod
    def build(cls, base):
        box = cls(base)
        for path in [box.proj, box.bin, box.tmp, box.state, box.sysroot / 'etc/init.d',
                     box.sysroot / 'etc/dnscrypt-proxy2', box.sysroot / 'etc/router-script/blinkit-hosts',
                     box.sysroot / 'sys/class/net/eth0', box.sysroot / 'var/run',
                     box.tmp / 'router-script-google']:
            path.mkdir(parents=True, exist_ok=True)
        for source in sorted(ROOT.glob('*.sh')):
            text = source.read_text()
            for old, new in REWRITES:
                text = text.replace(old, new)
            _write_exec(box.proj / source.name, text)
        for name in DATA_FILES:
            shutil.copy(ROOT / name, box.proj / name)
        tokens = {'@' + name.upper() + '@': shutil.which(name) for name in ['awk', 'cat', 'grep', 'mv', 'rm', 'sed', 'sort']}
        for name in REAL_TOOLS:
            (box.bin / name).symlink_to(shutil.which(name))
        (box.bin / 'sh').symlink_to(SHELL)
        if sys.platform == 'darwin':  # BusyBox/GNU `sed -i` takes no suffix argument; BSD sed needs one.
            _write_exec(box.bin / 'sed', '#!%s\nif [ "${1:-}" = -i ]; then shift; exec %s -i "" "$@"; fi\nexec %s "$@"\n'
                        % (SHELL, tokens['@SED@'], tokens['@SED@']))
        else:
            (box.bin / 'sed').symlink_to(tokens['@SED@'])
        for name, body in list(STUBS.items()) + [(name, ':') for name in NO_OPS]:
            for token, value in tokens.items():
                body = body.replace(token, value)
            _write_exec(box.bin / name, '#!%s\n%s%s\n' % (SHELL, PRELUDE, body))
        for name in SERVICES:
            _write_exec(box.sysroot / 'etc/init.d' / name, '#!%s\n%s:\n' % (SHELL, PRELUDE))
        (box.sysroot / 'sys/class/net/eth0/carrier').write_text('1\n')
        (box.sysroot / 'etc/dnscrypt-proxy2/dnscrypt-proxy.toml').write_text(
            "server_names = ['quad9-doh-ip4-port443-nofilter-ecs-pri']\n"
            "listen_addresses = ['127.0.0.1:5453']\nblock_ipv6 = false\n")
        (box.tmp / 'router-script-google/ranges.sha').write_text('simhash\n')
        (box.tmp / 'router-script-warp-ready').write_text('456\n')
        assert not (box.proj / '.env').exists() and not (box.proj / 'config.json').exists()
        return box

    @classmethod
    def fresh(cls, test):
        """Copy of a sandbox that already completed one healthy tick."""
        if cls._template is None:
            holder = tempfile.mkdtemp(prefix='router-sandbox-template-')
            atexit.register(shutil.rmtree, holder, True)
            template = cls.build(Path(holder) / 'box')
            result = template.run('ensure_network.sh')
            assert result.returncode == 0, result.stdout + result.stderr
            cls._template = template
        base = Path(tempfile.mkdtemp(prefix='router-sandbox-')) / 'box'
        test.addCleanup(shutil.rmtree, base.parent, True)
        shutil.copytree(cls._template.base, base, symlinks=True)
        box = cls(base)
        box.calls_file.write_text('')
        for log in (box.proj / 'logs').glob('*.log'):
            log.write_text('')
        return box

    def env(self, **extra):
        env = {
            'PATH': str(self.bin), 'HOME': str(self.tmp), 'LC_ALL': 'C',
            'SIM_LOG': str(self.calls_file), 'SIM_STATE': str(self.state), 'SIM_PROJ': str(self.proj),
            'SYSROOT': str(self.sysroot), 'SIMTMP': str(self.tmp),
            'BLINKIT_HOSTS_DIR': str(self.sysroot / 'etc/router-script/blinkit-hosts'),
            'PERSISTENT_STORAGE_FALLBACK_PERCENT': '101', 'TMP_MAX_USED_PERCENT': '101',
        }
        env.update(extra)
        return env

    def start(self, script, *args, **extra_env):
        """Start a script as its own process group, without waiting for it."""
        return subprocess.Popen([SHELL, str(self.proj / script), *args], env=self.env(**extra_env),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)

    def run(self, script, *args, timeout=120, **extra_env):
        process = self.start(script, *args, **extra_env)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise AssertionError('%s did not finish within %ss in the sandbox' % (script, timeout))
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def flag(self, name, on=True):
        path = self.state / name
        if on:
            path.write_text('')
        elif path.exists():
            path.unlink()

    def calls(self):
        return self.calls_file.read_text().splitlines()

    def count(self, prefix):
        return sum(1 for line in self.calls() if line.startswith(prefix))

    def log(self, name):
        path = self.proj / 'logs' / (name + '.log')
        return path.read_text() if path.exists() else ''

from pathlib import Path
import hashlib, io, subprocess, tarfile
root = Path(__file__).resolve().parents[2]
old = ['configure_dns.sh', 'ensure_network.sh', 'tunnel.sh']
new = ['google_wan_policy.sh', 'google_service_ranges.txt', 'google_domains.txt']
files = old + new
stage = '/root/router-script/.google-stage-20260923'
backup = '/root/router-script/google-backup-20260923'
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'root@192.168.8.1']
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w') as archive:
    for name in files:
        archive.add(root / name, arcname=name)
subprocess.run(ssh + [f'umask 077; mkdir {stage} && tar -xf - -C {stage}'], input=buf.getvalue(), check=True)
checks = []
for name in files:
    if name.endswith('.sh'):
        checks.append(f'sh -n {stage}/{name}')
    checks.append(f'[ "$(sha256sum {stage}/{name} | cut -d " " -f 1)" = "{hashlib.sha256((root/name).read_bytes()).hexdigest()}" ]')
for name in old:
    expected = hashlib.sha256((root/'audit/2026-09-23-google/before'/name).read_bytes()).hexdigest()
    checks.append(f'[ "$(sha256sum {name} | cut -d " " -f 1)" = "{expected}" ]')
script = r'''set -eu
cd /root/router-script
n=0
until mkdir .ensure_network.lock 2>/dev/null; do
 [ "$n" -lt 30 ] || exit 1
 sleep 1
 n=$((n+1))
done
CHANGED=0
cleanup() {
 status=$?
 trap - EXIT INT TERM
 if [ "$status" -ne 0 ] && [ "$CHANGED" -eq 1 ]; then
  for file in OLD_FILES; do cp "BACKUP/$file" "$file"; done
  cp BACKUP/dhcp /etc/config/dhcp
  for set in google_net4 google_dns4; do
   iptables -t mangle -D PREROUTING -i br-lan -m set --match-set "$set" dst -j MARK --set-xmark 0x100000/0x100000 2>/dev/null || true
   iptables -t mangle -D OUTPUT -m set --match-set "$set" dst -j MARK --set-xmark 0x100000/0x100000 2>/dev/null || true
  done
  for set in google_net6 google_dns6; do
   for chain in FORWARD OUTPUT; do
    if [ "$chain" = FORWARD ]; then iface='-i br-lan'; else iface=''; fi
    ip6tables -D "$chain" $iface -p tcp -m set --match-set "$set" dst -j REJECT --reject-with tcp-reset 2>/dev/null || true
    ip6tables -D "$chain" $iface -m set --match-set "$set" dst -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || true
   done
  done
  ip rule del priority 690 oif tun0 lookup main 2>/dev/null || true
  ip rule del priority 710 fwmark 0x100000/0x100000 table 102 2>/dev/null || true
  ip route flush table 102 2>/dev/null || true
  /etc/init.d/dnsmasq restart
 fi
 rmdir .ensure_network.lock
 exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CHECKS
! ip rule show | grep -Eq '^(690|710):'
[ -z "$(ip route show table 102 2>/dev/null)" ]
mkdir -m 700 BACKUP
for file in OLD_FILES; do cp -p "$file" "BACKUP/$file"; done
cp -p /etc/config/dhcp BACKUP/dhcp
chmod 600 BACKUP/dhcp
pidof usque-rs > BACKUP/tunnel-pid-before
CHANGED=1
for file in FILES; do cp -p "STAGE/$file" "$file"; done
sh ./google_wan_policy.sh
sh ./google_wan_policy.sh configure-dns
uci commit dhcp
/etc/init.d/dnsmasq restart
sh ./google_wan_policy.sh check-dns
sh ./google_wan_policy.sh
[ "$(ip rule show | grep -c '^710:')" -eq 1 ]
[ "$(ip rule show | grep -c '^690:')" -eq 1 ]
ip route get 8.8.8.8 mark 0x100000 | grep 'dev eth0'
printf 'Google direct IPv4 HTTP: '
curl -4 -sS --max-time 15 -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204
printf 'Google tunnel-bound IPv4 HTTP: '
curl -4 -sS --interface tun0 --max-time 15 -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204
printf 'Non-Google IPv6 HTTP: '
curl -6 -sS --interface tun0 --max-time 15 -o /dev/null -w '%{http_code}\n' https://cp.cloudflare.com/generate_204
[ "$(cat BACKUP/tunnel-pid-before)" = "$(pidof usque-rs)" ]
printf 'WARP PID unchanged: '; pidof usque-rs
CHANGED=0
'''
for token, value in [('OLD_FILES', ' '.join(old)), ('FILES', ' '.join(files)), ('BACKUP', backup), ('STAGE', stage), ('CHECKS', '\n'.join(checks))]:
    script = script.replace(token, value)
subprocess.run(ssh + ['sh -s'], input=script.encode(), check=True)

from pathlib import Path
import hashlib, io, subprocess, tarfile
root=Path(__file__).resolve().parents[2]
files=['configure_dns.sh','ensure_network.sh','tunnel.sh','refresh_blinkit_dns.sh']
old=files[:-1]
stage='/root/router-script/.blinkit-stage-20260919'
backup='/root/router-script/blinkit-backup-20260919'
ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','root@192.168.8.1']
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w') as archive:
 for name in files: archive.add(root/name,arcname=name)
subprocess.run(ssh+[f'umask 077; mkdir {stage} && tar -xf - -C {stage}'],input=buf.getvalue(),check=True)
checks=[]
for name in files:
 checks.append(f'sh -n {stage}/{name}')
 checks.append(f'[ "$(sha256sum {stage}/{name} | cut -d " " -f 1)" = "{hashlib.sha256((root/name).read_bytes()).hexdigest()}" ]')
 if name in old:
  expected=hashlib.sha256((root/'audit/2026-09-19-blinkit/before'/name).read_bytes()).hexdigest()
  checks.append(f'[ "$(sha256sum {name} | cut -d " " -f 1)" = "{expected}" ]')
script='''set -eu
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
  /etc/init.d/dnsmasq restart
 fi
 rmdir .ensure_network.lock
 exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CHECKS
mkdir -m 700 BACKUP
for file in OLD_FILES; do cp -p "$file" "BACKUP/$file"; done
cp -p /etc/config/dhcp BACKUP/dhcp
chmod 600 BACKUP/dhcp
pidof usque-rs > BACKUP/tunnel-pid-before
CHANGED=1
for file in FILES; do chmod 755 "STAGE/$file"; mv "STAGE/$file" "$file"; done
rmdir STAGE
sh ./refresh_blinkit_dns.sh
[ ! -f ./.env ] || . ./.env
BLINKIT_IPV4_DOMAINS="${BLINKIT_IPV4_DOMAINS:-api3.blinkit.com jumbo.blinkit.com}"
BLINKIT_HOSTS_DIR="${BLINKIT_HOSTS_DIR:-/etc/router-script/blinkit-hosts}"
for domain in $BLINKIT_IPV4_DOMAINS; do
 uci del_list dhcp.@dnsmasq[0].server="/$domain/" 2>/dev/null || true
 uci add_list dhcp.@dnsmasq[0].server="/$domain/"
done
uci del_list dhcp.@dnsmasq[0].addnhosts="$BLINKIT_HOSTS_DIR" 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].addnhosts="$BLINKIT_HOSTS_DIR"
uci commit dhcp
/etc/init.d/dnsmasq restart
sleep 2
for domain in $BLINKIT_IPV4_DOMAINS; do
 test -n "$(dig @127.0.0.1 "$domain" A +short +time=2 +tries=1)"
 test -z "$(dig @127.0.0.1 "$domain" AAAA +short +time=2 +tries=1)"
 dig @127.0.0.1 "$domain" AAAA +noall +comments +time=2 +tries=1 | grep 'status: NOERROR'
 for address in $(dig @127.0.0.1 "$domain" A +short); do
  ip -4 route get "$address" | grep 'dev eth0'
 done
done
test -n "$(dig @127.0.0.1 www.google.com AAAA +short +time=2 +tries=1)"
printf 'WARP PID before and after: '
cat BACKUP/tunnel-pid-before
pidof usque-rs
CHANGED=0
'''.replace('OLD_FILES',' '.join(old)).replace('FILES',' '.join(files)).replace('BACKUP',backup).replace('STAGE',stage).replace('CHECKS','\n'.join(checks))
subprocess.run(ssh+['sh -s'],input=script.encode(),check=True)

"""Deploy reviewed scripts without restarting services; preserve rollback copies."""
from pathlib import Path
import hashlib
import io
import subprocess
import tarfile
ROOT = Path(__file__).resolve().parents[2]
files = ['configure_dns.sh','configure_lan_ipv6.sh','diagnose.sh','dns_flow.sh','ensure_network.sh','game_mode.sh','monitor_game_network.sh','rotate_logs.sh','tunnel.sh']
ssh = ['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','root@192.168.8.1']
stage = '/root/router-script/.audit-stage-20260919'
backup = '/root/router-script/audit-backup-20260919'
# No secret files are transferred.
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w') as archive:
 for name in files: archive.add(ROOT/name,arcname=name)
subprocess.run(ssh+[f'umask 077; mkdir {stage} && tar -xf - -C {stage}'],input=buf.getvalue(),check=True)
checks=[]
for name in files:
 expected=hashlib.sha256((ROOT/'audit/2026-09-19/before'/name).read_bytes()).hexdigest()
 new=hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
 checks.append(f'[ "$(sha256sum {name} | cut -d " " -f 1)" = "{expected}" ]')
 checks.append(f'[ "$(sha256sum {stage}/{name} | cut -d " " -f 1)" = "{new}" ]')
 checks.append(f'sh -n {stage}/{name}')
script='''set -eu
cd /root/router-script
n=0
until mkdir .ensure_network.lock 2>/dev/null; do
 [ "$n" -lt 30 ] || exit 1
 sleep 1
 n=$((n+1))
done
PROMOTING=0
cleanup() {
 status=$?
 trap - EXIT INT TERM
 if [ "$status" -ne 0 ] && [ "$PROMOTING" -eq 1 ]; then
  for file in FILES; do cp "BACKUP/$file" "$file"; done
 fi
 rmdir .ensure_network.lock
 exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CHECKS
mkdir -m 700 BACKUP
for file in FILES; do cp -p "$file" "BACKUP/$file"; done
pidof usque-rs > BACKUP/tunnel-pid-before
PROMOTING=1
for file in FILES; do chmod 755 "STAGE/$file"; mv "STAGE/$file" "$file"; done
rmdir STAGE
PROMOTING=0
printf 'Installed scripts; tunnel PID before/after: '
cat BACKUP/tunnel-pid-before
pidof usque-rs
'''.replace('FILES',' '.join(files)).replace('BACKUP',backup).replace('STAGE',stage).replace('CHECKS','\n'.join(checks))
subprocess.run(ssh+['sh -s'],input=script.encode(),check=True)

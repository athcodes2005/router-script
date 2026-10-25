from pathlib import Path
import hashlib, io, subprocess, tarfile

root = Path(__file__).resolve().parents[2]
files = ['tunnel.sh', 'stop_tunnel.sh', 'ensure_network.sh']
stage = '/root/router-script/.mss-stage-20261008'
backup = '/root/router-script/mss-backup-20261008'
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'root@192.168.8.1']

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w') as archive:
    for name in files:
        archive.add(root / name, arcname=name)

# Upload to stage directory
subprocess.run(ssh + [f'rm -rf {stage} && umask 077; mkdir -p {stage} && tar -xf - -C {stage}'], input=buf.getvalue(), check=True)

# Verification checks
checks = []
for name in files:
    checks.append(f'sh -n {stage}/{name}')
    expected_hash = hashlib.sha256((root / name).read_bytes()).hexdigest()
    checks.append(f'[ "$(sha256sum {stage}/{name} | cut -d " " -f 1)" = "{expected_hash}" ]')

for name in files:
    before_hash = hashlib.sha256((root / 'audit/2026-10-08-mss-clamping/before' / name).read_bytes()).hexdigest()
    checks.append(f'[ "$(sha256sum {name} | cut -d " " -f 1)" = "{before_hash}" ]')

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
        for file in FILES; do cp "BACKUP/$file" "$file"; done
        iptables -t mangle -D FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        ip6tables -t mangle -D FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
    fi
    rm -rf STAGE
    rmdir .ensure_network.lock 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CHECKS

mkdir -m 700 -p BACKUP
for file in FILES; do cp -p "$file" "BACKUP/$file"; done
pidof usque-rs > BACKUP/tunnel-pid-before
CHANGED=1

for file in FILES; do cp -p "STAGE/$file" "$file"; chmod 755 "$file"; done

# Apply live inbound TCPMSS rules without restarting WARP
iptables -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || \
    iptables -t mangle -I FORWARD 1 -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
ip6tables -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || \
    ip6tables -t mangle -I FORWARD 1 -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220

# Run health check to confirm
sh ./ensure_network.sh

[ "$(cat BACKUP/tunnel-pid-before)" = "$(pidof usque-rs)" ]
printf 'WARP PID preserved: %s\n' "$(pidof usque-rs)"

CHANGED=0
'''

for token, value in [('FILES', ' '.join(files)), ('BACKUP', backup), ('STAGE', stage), ('CHECKS', '\n'.join(checks))]:
    script = script.replace(token, value)

subprocess.run(ssh + ['sh -s'], input=script.encode(), check=True)
print("Deployment completed successfully!")

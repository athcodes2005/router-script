#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${ROUTER_SSH_TARGET:-root@192.168.8.1}"
REMOTE_DIR="${ROUTER_SCRIPT_DIR:-/root/router-script}"
LOCAL_STAGE="$(mktemp -d "$DIR/.sync-from.XXXXXX")"

cleanup() {
    STATUS=$?
    trap - EXIT INT TERM
    rm -rf "$LOCAL_STAGE"
    exit "$STATUS"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# OpenWrt's dropbear has no sftp-server, and OpenSSH 9+ scp defaults to SFTP:
# force the legacy SCP protocol or every transfer fails with
# "/usr/libexec/sftp-server: not found" (F51).
run_scp() {
    scp -O -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
}

mkdir -p "$DIR/logs" "$DIR/diagnostics"

echo "Pulling config.json..."
if run_scp "$REMOTE:$REMOTE_DIR/config.json" "$LOCAL_STAGE/config.json" 2>/dev/null \
    && [ -s "$LOCAL_STAGE/config.json" ] \
    && grep -q '"endpoint_v4"' "$LOCAL_STAGE/config.json" \
    && grep -q '"private_key"' "$LOCAL_STAGE/config.json"; then
    chmod 600 "$LOCAL_STAGE/config.json"
    mv "$LOCAL_STAGE/config.json" "$DIR/config.json"
else
    echo "WARNING: config.json pull failed validation; preserving the local copy." >&2
fi

# The blocklist is edited on the router as often as it is here, so it has to
# come back — otherwise the next sync_to_router.sh overwrites the router's copy.
echo "Pulling blocked_sites.txt..."
if run_scp "$REMOTE:$REMOTE_DIR/blocked_sites.txt" "$LOCAL_STAGE/blocked_sites.txt" 2>/dev/null; then
    mv "$LOCAL_STAGE/blocked_sites.txt" "$DIR/blocked_sites.txt"
fi

echo "Pulling warp_clients.txt..."
if run_scp "$REMOTE:$REMOTE_DIR/warp_clients.txt" "$LOCAL_STAGE/warp_clients.txt" 2>/dev/null; then
    mv "$LOCAL_STAGE/warp_clients.txt" "$DIR/warp_clients.txt"
fi

echo "Pulling logs..."
run_scp "$REMOTE:$REMOTE_DIR/logs/*.log" "$DIR/logs/" 2>/dev/null || true
run_scp "$REMOTE:$REMOTE_DIR/logs/*.log.*" "$DIR/logs/" 2>/dev/null || true

echo "Pulling diagnostics..."
run_scp "$REMOTE:$REMOTE_DIR/diagnostics/*.log" "$DIR/diagnostics/" 2>/dev/null || true

echo "Pulled router state into $DIR"

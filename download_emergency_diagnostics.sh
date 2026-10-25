#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

. "$DIR/paths.sh"

REMOTE="${ROUTER_SSH_TARGET:-root@192.168.8.1}"
REMOTE_DIR="${ROUTER_SCRIPT_DIR:-/root/router-script}"

run_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
}

# OpenWrt's dropbear has no sftp-server, and OpenSSH 9+ scp defaults to SFTP:
# force the legacy SCP protocol or every transfer fails with
# "/usr/libexec/sftp-server: not found" (F51).
run_scp() {
    scp -O -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
}

REMOTE_OUTPUT_FILE="$(run_ssh "$REMOTE" "cd '$REMOTE_DIR' && ./collect_diagnostics.sh --emergency" | tail -n 1)"

if [ -z "$REMOTE_OUTPUT_FILE" ]; then
    echo "Failed to get emergency diagnostic path from router." >&2
    exit 1
fi

case "$REMOTE_OUTPUT_FILE" in
    "$REMOTE_DIR"/diagnostics/emergency_*.log) ;;
    *)
        echo "Router returned an unexpected diagnostic path; refusing to copy it." >&2
        exit 1
        ;;
esac

LOCAL_OUTPUT_FILE="$DIAGNOSTICS_DIR/$(basename "$REMOTE_OUTPUT_FILE")"
run_scp "$REMOTE:$REMOTE_OUTPUT_FILE" "$LOCAL_OUTPUT_FILE"

printf 'Downloaded emergency diagnostic to %s\n' "$LOCAL_OUTPUT_FILE"

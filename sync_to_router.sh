#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${ROUTER_SSH_TARGET:-root@192.168.8.1}"
REMOTE_DIR="${ROUTER_SCRIPT_DIR:-/root/router-script}"
EXECUTABLE_BASENAME="$(basename "$DIR/usque-rs")"
WAS_RUNNING=0
LOCK_HELD=0
REMOTE_STAGE="$REMOTE_DIR/.sync-stage-$$"

run_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
}

run_scp() {
    scp -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
}

# Older macOS releases have shasum but no sha256sum.
local_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

cleanup() {
    STATUS=$?
    trap - EXIT INT TERM

    run_ssh "$REMOTE" "rm -rf '$REMOTE_STAGE'" >/dev/null 2>&1 || true

    if [ "$WAS_RUNNING" -eq 1 ] && ! run_ssh "$REMOTE" "pidof '$EXECUTABLE_BASENAME' >/dev/null 2>&1"; then
        echo "Restarting tunnel."
        run_ssh "$REMOTE" "cd '$REMOTE_DIR' && ./tunnel.sh >/dev/null 2>&1" || true
    fi

    if [ "$LOCK_HELD" -eq 1 ]; then
        run_ssh "$REMOTE" "rmdir '$REMOTE_DIR/.ensure_network.lock' 2>/dev/null || true" >/dev/null 2>&1 || true
    fi

    exit "$STATUS"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

chmod 600 "$DIR/.env" "$DIR/config.json" 2>/dev/null || true

# Use --force to push a blocklist or config.json that diverges from the router's copy.
FORCE=0
case "${1:-}" in
    --force|-f) FORCE=1 ;;
esac

echo "Preparing remote directory on $REMOTE:$REMOTE_DIR"
run_ssh "$REMOTE" "mkdir -p '$REMOTE_DIR/logs' '$REMOTE_DIR/diagnostics'"

# blocked_sites.txt gets edited on the router too. Pushing a stale local copy
# silently drops those entries, and the routes vanish at the next tunnel
# restart — so refuse to push over a router copy we do not already match.
REMOTE_BLOCKLIST="$(run_ssh "$REMOTE" "cat '$REMOTE_DIR/blocked_sites.txt' 2>/dev/null" || true)"
if [ -n "$REMOTE_BLOCKLIST" ] && [ "$REMOTE_BLOCKLIST" != "$(cat "$DIR/blocked_sites.txt" 2>/dev/null)" ]; then
    if [ "$FORCE" -eq 0 ]; then
        echo "ERROR: blocked_sites.txt differs between local and the router." >&2
        echo "Run ./sync_from_router.sh to pull the router's copy first," >&2
        echo "or re-run with --force to overwrite it." >&2
        exit 1
    fi
    echo "WARNING: overwriting the router's blocked_sites.txt (--force)."
fi

# rotate_tunnel_ip.sh registers a new WARP identity on the router, so the local
# config.json can be stale; pushing it would undo the rotation. Only hashes are
# compared: the file holds the private key and is never printed.
if [ -f "$DIR/config.json" ]; then
    REMOTE_CONFIG_SHA="$(run_ssh "$REMOTE" "sha256sum '$REMOTE_DIR/config.json' 2>/dev/null | awk '{print \$1}'" || true)"
    if [ -n "$REMOTE_CONFIG_SHA" ] && [ "$REMOTE_CONFIG_SHA" != "$(local_sha256 "$DIR/config.json")" ]; then
        if [ "$FORCE" -eq 0 ]; then
            echo "ERROR: config.json differs between local and the router (rotated on the router?)." >&2
            echo "Run ./sync_from_router.sh to pull the router's copy first," >&2
            echo "or re-run with --force to overwrite it." >&2
            exit 1
        fi
        echo "WARNING: overwriting the router's config.json (--force)."
    fi
fi

if run_ssh "$REMOTE" "pidof '$EXECUTABLE_BASENAME' >/dev/null 2>&1"; then
    WAS_RUNNING=1
fi

echo "Acquiring router maintenance lock."
run_ssh "$REMOTE" "
    i=0
    while ! mkdir '$REMOTE_DIR/.ensure_network.lock' 2>/dev/null; do
        [ \"\$i\" -ge 30 ] && exit 1
        sleep 1
        i=\$((i + 1))
    done
"
LOCK_HELD=1

# Sync into a private staging directory first, then promote the complete set.
# A failed transfer therefore leaves the installed scripts untouched.
FILES="usque-rs usque-rs-upstream-v0.1.0 config.json .env blocked_sites.txt warp_clients.txt paths.sh lock.sh login.sh tunnel.sh stop_tunnel.sh game_mode.sh monitor_game_network.sh configure_wifi.sh configure_dns.sh refresh_blinkit_dns.sh google_wan_policy.sh google_service_ranges.txt google_domains.txt configure_lan_ipv6.sh ensure_network.sh diagnose.sh collect_diagnostics.sh dns_flow.sh rotate_logs.sh install_cron_pipeline.sh bootstrap_router.sh download_emergency_diagnostics.sh rotate_tunnel_ip.sh firewall_hook.sh install_firewall_hook.sh PROJECT_CONTEXT.md README.md"

echo "Staging project files on the router."
run_ssh "$REMOTE" "rm -rf '$REMOTE_STAGE' && mkdir -m 700 '$REMOTE_STAGE'"
for FILE in $FILES; do
    [ -f "$DIR/$FILE" ] && run_scp -q "$DIR/$FILE" "$REMOTE:$REMOTE_STAGE/$FILE"
done

if [ "$WAS_RUNNING" -eq 1 ]; then
    echo "Tunnel is running. Stopping before sync."
    run_ssh "$REMOTE" "cd '$REMOTE_DIR' && ./stop_tunnel.sh"
fi

echo "Promoting staged files."
run_ssh "$REMOTE" "
    set -e
    for FILE in $FILES; do
        [ -f '$REMOTE_STAGE'/\"\$FILE\" ] && mv '$REMOTE_STAGE'/\"\$FILE\" '$REMOTE_DIR'/\"\$FILE\"
    done
    rmdir '$REMOTE_STAGE'
    cd '$REMOTE_DIR'
    chmod 755 ./*.sh ./usque-rs
    [ ! -f ./usque-rs-upstream-v0.1.0 ] || chmod 755 ./usque-rs-upstream-v0.1.0
    chmod 600 ./.env ./config.json
    # A power cut seconds after a deploy must not leave zero-length files.
    sync
"

echo "Router sync complete."

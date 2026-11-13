#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${ROUTER_SSH_TARGET:-root@192.168.8.1}"
REMOTE_DIR="${ROUTER_SCRIPT_DIR:-/root/router-script}"
EXECUTABLE_BASENAME="$(basename "$DIR/usque-rs")"
WAS_RUNNING=0
REMOTE_STAGE="$REMOTE_DIR/.sync-stage-$$"
# How long the promotion waits for a health check or game-mode toggle to finish.
SYNC_LOCK_WAIT="${SYNC_LOCK_WAIT:-30}"

run_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
}

# OpenWrt's dropbear has no sftp-server, and OpenSSH 9+ scp defaults to SFTP:
# force the legacy SCP protocol or every transfer fails with
# "/usr/libexec/sftp-server: not found" (F51).
run_scp() {
    scp -O -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$@"
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

    # Through the health check, which starts the tunnel under the maintenance
    # lock and then tests it: a bare tunnel.sh could collide with a cron tick
    # starting the tunnel at the same moment.
    if [ "$WAS_RUNNING" -eq 1 ] && ! run_ssh "$REMOTE" "pidof '$EXECUTABLE_BASENAME' >/dev/null 2>&1"; then
        echo "Restarting tunnel."
        run_ssh "$REMOTE" "cd '$REMOTE_DIR' && ROUTER_SCRIPT_TRIGGER=gate ./ensure_network.sh >/dev/null 2>&1" ||
            echo "WARNING: the router's health check did not confirm a working tunnel; see logs/ensure.log there." >&2
    fi

    exit "$STATUS"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

chmod 600 "$DIR/.env" "$DIR/config.json" 2>/dev/null || true

if [ ! -f "$DIR/usque-rs" ] && [ -f "$DIR/fetch_usque_rs.sh" ]; then
    sh "$DIR/fetch_usque_rs.sh" --download-only || true
fi

# Use --force to push a blocklist, .env or config.json that diverges from the
# router's copy, and --push-binary to replace the router's usque-rs with a
# different one.
FORCE=0
PUSH_BINARY=0
for ARG in "$@"; do
    case "$ARG" in
        --force|-f) FORCE=1 ;;
        --push-binary) PUSH_BINARY=1 ;;
    esac
done

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
# The router's .env can hold settings the local copy lacks, and pushing the
# local file would drop them without a word. It holds credentials, so it is
# compared by hash and never pulled or printed.
if [ -f "$DIR/.env" ]; then
    REMOTE_ENV_SHA="$(run_ssh "$REMOTE" "sha256sum '$REMOTE_DIR/.env' 2>/dev/null | awk '{print \$1}'" || true)"
    if [ -n "$REMOTE_ENV_SHA" ] && [ "$REMOTE_ENV_SHA" != "$(local_sha256 "$DIR/.env")" ]; then
        if [ "$FORCE" -eq 0 ]; then
            echo "ERROR: .env differs between local and the router." >&2
            echo "Bring the two in line by hand (it is never pulled)," >&2
            echo "or re-run with --force to overwrite the router's copy." >&2
            exit 1
        fi
        echo "WARNING: overwriting the router's .env (--force)."
    fi
fi

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

# The router's fetch_usque_rs.sh keeps usque-rs at the release pinned in
# defaults.sh, while the local copy is fetched once and then goes stale. Pushing
# it would downgrade the router for good: .usque_release_sha is not shipped, so
# the fetcher would still read the pinned release as installed. A router that
# has a binary therefore keeps it, unless --push-binary asks otherwise.
SHIP_BINARY=1
if [ -f "$DIR/usque-rs" ]; then
    REMOTE_BINARY_SHA="$(run_ssh "$REMOTE" "sha256sum '$REMOTE_DIR/usque-rs' 2>/dev/null | awk '{print \$1}'" || true)"
    if [ -z "$REMOTE_BINARY_SHA" ]; then
        :
    elif [ "$REMOTE_BINARY_SHA" = "$(local_sha256 "$DIR/usque-rs")" ]; then
        SHIP_BINARY=0
    elif [ "$PUSH_BINARY" -eq 1 ]; then
        echo "WARNING: replacing the router's usque-rs with the local copy (--push-binary)."
    else
        SHIP_BINARY=0
        echo "NOTE: the router's usque-rs differs from the local copy and is left as it is."
        echo "      The router fetches the pinned release itself; --push-binary sends the local one."
    fi
fi

if run_ssh "$REMOTE" "pidof '$EXECUTABLE_BASENAME' >/dev/null 2>&1"; then
    WAS_RUNNING=1
fi

# Sync into a private staging directory first, then promote the complete set.
# A failed transfer therefore leaves the installed scripts untouched. The
# helpers other scripts source come first: promotion follows this order.
FILES="paths.sh lock.sh defaults.sh usque-rs config.json .env blocked_sites.txt warp_clients.txt login.sh tunnel.sh stop_tunnel.sh game_mode.sh monitor_game_network.sh configure_wifi.sh configure_dns.sh refresh_blinkit_dns.sh google_wan_policy.sh google_service_ranges.txt google_domains.txt configure_lan_ipv6.sh ensure_network.sh diagnose.sh collect_diagnostics.sh dns_flow.sh rotate_logs.sh install_cron_pipeline.sh bootstrap_router.sh download_emergency_diagnostics.sh rotate_tunnel_ip.sh firewall_hook.sh install_firewall_hook.sh promote_staged.sh measure_load_latency.sh fetch_usque_rs.sh update_from_git.sh README.md"

echo "Staging project files on the router."
run_ssh "$REMOTE" "rm -rf '$REMOTE_STAGE' && mkdir -m 700 '$REMOTE_STAGE'"
MANIFEST=
for FILE in $FILES; do
    [ -f "$DIR/$FILE" ] || continue
    [ "$FILE" != usque-rs ] || [ "$SHIP_BINARY" -eq 1 ] || continue
    MANIFEST="$MANIFEST$(local_sha256 "$DIR/$FILE")  $FILE
"
    run_scp -q "$DIR/$FILE" "$REMOTE:$REMOTE_STAGE/$FILE"
done
printf '%s' "$MANIFEST" | run_ssh "$REMOTE" "cat > '$REMOTE_STAGE/.manifest'"

# One remote process checks the staged set, then stops the tunnel and promotes
# it while it owns the maintenance lock; see promote_staged.sh.
echo "Promoting staged files."
run_ssh "$REMOTE" "sh '$REMOTE_STAGE/promote_staged.sh' '$REMOTE_DIR' '$SYNC_LOCK_WAIT'"

# Tell update_from_git.sh that the router already runs the deploy branch's
# commit, so it does not fetch and promote the same files again. That is true
# only of a checkout at that commit with no uncommitted change to a tracked
# file. Any other sync leaves the record alone: CI moves the branch to a commit
# minutes after the push, and naming a commit the branch has not reached would
# make the updater put the branch's older one back.
DEPLOY_REF="origin/${DEPLOY_BRANCH:-deploy}"
if DEPLOYED_COMMIT="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" &&
    [ -z "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    if [ "$DEPLOYED_COMMIT" = "$(git -C "$DIR" rev-parse --verify --quiet "$DEPLOY_REF^{commit}" 2>/dev/null)" ]; then
        run_ssh "$REMOTE" "printf '%s\n' '$DEPLOYED_COMMIT' > '$REMOTE_DIR/.deployed_commit'"
        echo "Recorded $DEPLOYED_COMMIT as the deployed commit."
    else
        echo "NOTE: this checkout is not at $DEPLOY_REF (as of the last git fetch);"
        echo "      the router's record of its deployed commit is left as it is."
    fi
fi

echo "Router sync complete."

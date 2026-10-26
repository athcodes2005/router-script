#!/bin/sh
# Pull the deploy branch from GitHub, verify its CI passed, promote the new
# files under the maintenance lock, verify health, and roll back if the
# post-update health check fails.
#
# Configuration in .env (all optional; if GITHUB_REPO is unset, this exits 0):
#   GITHUB_REPO=owner/router-script
#   GITHUB_TOKEN=<fine-grained read-only token>
#   DEPLOY_BRANCH=deploy
#   GITHUB_API_URL=https://api.github.com

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"
LOG_FILE="$(prepare_log_file maintenance)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi
. "$DIR/defaults.sh"

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-deploy}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
DEPLOY_COMMIT_FILE="${DEPLOY_COMMIT_FILE:-$DIR/.deployed_commit}"
UPDATE_LOCK_WAIT="${UPDATE_LOCK_WAIT:-30}"

# Check for new usque-rs releases from USQUE_REPO when enabled.
if [ -x "$DIR/fetch_usque_rs.sh" ] && [ "${AUTO_FETCH_USQUE:-1}" = "1" ]; then
    sh "$DIR/fetch_usque_rs.sh" || true
fi

# Nothing to do for scripts until a repository is configured.
[ -n "$GITHUB_REPO" ] || exit 0

log() {
    printf '%s - [updater] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

WORK="$(mktemp -d /tmp/router-git-update.XXXXXX)"
STAGE="$DIR/.git-stage-$$"
BACKUP="$DIR/.git-backup-$$"

cleanup() {
    rm -rf "$WORK" "$STAGE" "$BACKUP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' HUP PIPE

# Pass the bearer token on stdin (-K -) so it never appears in /proc/<pid>/cmdline.
github_curl() {
    if [ -n "$GITHUB_TOKEN" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
            curl -fsSL --connect-timeout 5 --max-time 30 -K - \
                -H "Accept: application/vnd.github+json" "$@"
    else
        curl -fsSL --connect-timeout 5 --max-time 30 \
            -H "Accept: application/vnd.github+json" "$@"
    fi
}

COMMIT_JSON="$WORK/commit.json"
if ! github_curl "$GITHUB_API_URL/repos/$GITHUB_REPO/commits/$DEPLOY_BRANCH" -o "$COMMIT_JSON" 2>/dev/null; then
    log "WARNING: could not fetch $GITHUB_REPO@$DEPLOY_BRANCH from GitHub."
    exit 0
fi

TARGET_SHA="$(jsonfilter -i "$COMMIT_JSON" -e '@.sha' 2>/dev/null || true)"
case "$TARGET_SHA" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *)
        log "WARNING: invalid commit SHA from GitHub for $DEPLOY_BRANCH."
        exit 0 ;;
esac

CURRENT_SHA="$(cat "$DEPLOY_COMMIT_FILE" 2>/dev/null || true)"
if [ "$TARGET_SHA" = "$CURRENT_SHA" ]; then
    exit 0
fi

# Require every completed check-run on the commit to have succeeded, and at
# least one check-run to exist (CI must have passed on this commit).
CHECKS_JSON="$WORK/checks.json"
if ! github_curl "$GITHUB_API_URL/repos/$GITHUB_REPO/commits/$TARGET_SHA/check-runs" -o "$CHECKS_JSON" 2>/dev/null; then
    log "WARNING: could not fetch CI check-runs for $TARGET_SHA; skipping update."
    exit 0
fi

TOTAL_CHECKS="$(jsonfilter -i "$CHECKS_JSON" -e '@.total_count' 2>/dev/null || echo 0)"
case "$TOTAL_CHECKS" in ''|*[!0-9]*) TOTAL_CHECKS=0 ;; esac
if [ "$TOTAL_CHECKS" -lt 1 ]; then
    log "Skipping $TARGET_SHA: no CI check-runs recorded yet."
    exit 0
fi

CONCLUSIONS="$(jsonfilter -i "$CHECKS_JSON" -e '@.check_runs[*].conclusion' 2>/dev/null || true)"
STATUSES="$(jsonfilter -i "$CHECKS_JSON" -e '@.check_runs[*].status' 2>/dev/null || true)"
for ST in $STATUSES; do
    if [ "$ST" != "completed" ]; then
        log "Skipping $TARGET_SHA: CI check-run is still $ST."
        exit 0
    fi
done
for CONC in $CONCLUSIONS; do
    case "$CONC" in
        success|neutral|skipped) ;;
        *)
            log "Skipping $TARGET_SHA: CI check-run concluded '$CONC'."
            exit 0 ;;
    esac
done

TARBALL="$WORK/repo.tar.gz"
if ! github_curl "$GITHUB_API_URL/repos/$GITHUB_REPO/tarball/$TARGET_SHA" -o "$TARBALL" 2>/dev/null; then
    log "WARNING: failed to download tarball for $TARGET_SHA."
    exit 1
fi

mkdir -p "$WORK/extracted"
tar -xzf "$TARBALL" -C "$WORK/extracted"
SRC_DIR="$(find "$WORK/extracted" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/ensure_network.sh" ]; then
    log "ERROR: archive for $TARGET_SHA is missing ensure_network.sh."
    exit 1
fi

for SCRIPT in "$SRC_DIR"/*.sh; do
    [ -f "$SCRIPT" ] || continue
    if ! sh -n "$SCRIPT" 2>/dev/null; then
        log "ERROR: syntax check failed on $(basename "$SCRIPT") in $TARGET_SHA; aborting update."
        exit 1
    fi
done

# Deployable files from git (never .env, config.json, or blocked_sites.txt if edited locally).
DEPLOY_FILES="paths.sh lock.sh defaults.sh usque-rs usque-rs-upstream-v0.1.0 warp_clients.txt login.sh tunnel.sh stop_tunnel.sh game_mode.sh monitor_game_network.sh configure_wifi.sh configure_dns.sh refresh_blinkit_dns.sh google_wan_policy.sh google_service_ranges.txt google_domains.txt configure_lan_ipv6.sh ensure_network.sh diagnose.sh collect_diagnostics.sh dns_flow.sh rotate_logs.sh install_cron_pipeline.sh bootstrap_router.sh download_emergency_diagnostics.sh rotate_tunnel_ip.sh firewall_hook.sh install_firewall_hook.sh promote_staged.sh measure_load_latency.sh fetch_usque_rs.sh update_from_git.sh README.md"

rm -rf "$STAGE" "$BACKUP"
mkdir -m 700 "$STAGE" "$BACKUP"

MANIFEST=
for FILE in $DEPLOY_FILES; do
    [ -f "$SRC_DIR/$FILE" ] || continue
    cp "$SRC_DIR/$FILE" "$STAGE/$FILE"
    HASH="$(sha256sum "$STAGE/$FILE" | awk '{print $1}')"
    MANIFEST="$MANIFEST$HASH  $FILE
"
    if [ -f "$DIR/$FILE" ]; then
        cp -p "$DIR/$FILE" "$BACKUP/$FILE"
    fi
done
printf '%s' "$MANIFEST" > "$STAGE/.manifest"

WAS_RUNNING=0
if pidof usque-rs >/dev/null 2>&1; then
    WAS_RUNNING=1
fi

log "Promoting commit $TARGET_SHA from $GITHUB_REPO@$DEPLOY_BRANCH."
if ! sh "$STAGE/promote_staged.sh" "$DIR" "$UPDATE_LOCK_WAIT" >> "$LOG_FILE" 2>&1; then
    log "ERROR: promotion of $TARGET_SHA failed."
    exit 1
fi

if [ "$WAS_RUNNING" -eq 1 ] && ! pidof usque-rs >/dev/null 2>&1; then
    sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
fi

# Health gate: run ensure_network.sh; if it fails, roll back immediately.
if sh "$DIR/ensure_network.sh" >> "$LOG_FILE" 2>&1; then
    printf '%s\n' "$TARGET_SHA" > "$DEPLOY_COMMIT_FILE"
    sync
    log "Update to $TARGET_SHA succeeded and passed the health check."
    exit 0
fi

log "ERROR: health check failed after promoting $TARGET_SHA; rolling back."
ROLLBACK_STAGE="$DIR/.git-rollback-$$"
rm -rf "$ROLLBACK_STAGE"
mkdir -m 700 "$ROLLBACK_STAGE"
RMANIFEST=
for FILE in $DEPLOY_FILES; do
    [ -f "$BACKUP/$FILE" ] || continue
    cp -p "$BACKUP/$FILE" "$ROLLBACK_STAGE/$FILE"
    RHASH="$(sha256sum "$ROLLBACK_STAGE/$FILE" | awk '{print $1}')"
    RMANIFEST="$RMANIFEST$RHASH  $FILE
"
done
printf '%s' "$RMANIFEST" > "$ROLLBACK_STAGE/.manifest"
sh "$ROLLBACK_STAGE/promote_staged.sh" "$DIR" "$UPDATE_LOCK_WAIT" >> "$LOG_FILE" 2>&1 || true
rm -rf "$ROLLBACK_STAGE"
if [ "$WAS_RUNNING" -eq 1 ] && ! pidof usque-rs >/dev/null 2>&1; then
    sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
fi
sh "$DIR/ensure_network.sh" >> "$LOG_FILE" 2>&1 || true
log "Rolled back from $TARGET_SHA to ${CURRENT_SHA:-previous state}."
exit 1

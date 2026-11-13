#!/bin/sh
# Pull the deploy branch from GitHub, promote the new files under the
# maintenance lock, verify health, and roll back if the post-update health
# check fails.
#
# Configuration in .env (all optional; if GITHUB_REPO is unset, this exits 0):
#   GITHUB_REPO=owner/router-script
#   DEPLOY_BRANCH=deploy
#   GITHUB_URL=https://github.com
#
# Nothing here uses the GitHub API or a token. Anonymous API calls are limited
# to 60 an hour per address, and the router shares its WARP or campus address
# with many others, so they are refused most of the time. The branch head comes
# from the ref listing a Git client reads before a fetch and the files from the
# commit's archive; neither counts against that limit. The repository must be
# public.
#
# A commit's CI result can only be read through the API, so CI decides before
# the router looks: the promote job in .github/workflows/ci.yml moves the deploy
# branch to a commit of main once that commit's checks have passed. Nothing else
# should push to the branch, because the router installs whatever it points at.
#
# A commit that fails the post-update health check is rolled back and recorded
# in .git_failed_commit; later runs skip it. The skip ends when the deploy
# branch moves to another commit, when that file is removed, or with
# ./update_from_git.sh --retry-failed (which is also passed to fetch_usque_rs.sh).
# A commit the health check could not test (it exits 75; see ensure_network.sh)
# is rolled back too, but not recorded: the next run tries it again.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

# .env first, so LOG_DIR / DIAGNOSTICS_DIR overrides reach paths.sh.
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi
. "$DIR/paths.sh"
LOG_FILE="$(prepare_log_file maintenance)"

. "$DIR/defaults.sh"

RETRY_FAILED=0
for ARG in "$@"; do
    [ "$ARG" != "--retry-failed" ] || RETRY_FAILED=1
done

GITHUB_REPO="${GITHUB_REPO:-}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-deploy}"
GITHUB_URL="${GITHUB_URL:-https://github.com}"
DEPLOY_COMMIT_FILE="${DEPLOY_COMMIT_FILE:-$DIR/.deployed_commit}"
GIT_FAILED_FILE="${GIT_FAILED_FILE:-$DIR/.git_failed_commit}"
UPDATE_LOCK_WAIT="${UPDATE_LOCK_WAIT:-30}"

# Check for new usque-rs releases from USQUE_REPO when enabled.
if [ -x "$DIR/fetch_usque_rs.sh" ] && [ "${AUTO_FETCH_USQUE:-1}" = "1" ]; then
    if [ "$RETRY_FAILED" -eq 1 ]; then
        sh "$DIR/fetch_usque_rs.sh" --retry-failed || true
    else
        sh "$DIR/fetch_usque_rs.sh" || true
    fi
fi

# Nothing to do for scripts until a repository is configured.
[ -n "$GITHUB_REPO" ] || exit 0

log() {
    printf '%s - [updater] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

. "$DIR/lock.sh"

WORK="$(mktemp -d /tmp/router-git-update.XXXXXX)"
STAGE="$DIR/.git-stage-$$"
BACKUP="$DIR/.git-backup-$$"

cleanup() {
    release_maintenance_lock
    rm -rf "$WORK" "$STAGE" "$BACKUP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' HUP PIPE

github_curl() {
    curl -fsSL --connect-timeout 5 --max-time 30 "$@"
}

# The ref listing is a run of pkt-lines, "<4 hex length><40 hex commit> <ref>";
# the first ref also carries a NUL and the server's capabilities, and follows a
# "0000" flush packet without a line break. The commit is therefore the last 40
# characters of the first field.
REFS="$WORK/refs"
if ! github_curl "$GITHUB_URL/$GITHUB_REPO.git/info/refs?service=git-upload-pack" -o "$REFS" 2>/dev/null; then
    log "WARNING: could not fetch the branches of $GITHUB_REPO from GitHub."
    exit 0
fi

TARGET_SHA="$(tr '\000' '\n' < "$REFS" |
    awk -v ref="refs/heads/$DEPLOY_BRANCH" '$2 == ref { print substr($1, length($1) - 39); exit }')"
case "$TARGET_SHA" in
    *[!0-9a-f]*) TARGET_SHA= ;;
esac
if [ "${#TARGET_SHA}" -ne 40 ]; then
    log "WARNING: GitHub lists no commit for branch $DEPLOY_BRANCH of $GITHUB_REPO."
    exit 0
fi

CURRENT_SHA="$(cat "$DEPLOY_COMMIT_FILE" 2>/dev/null || true)"
if [ "$TARGET_SHA" = "$CURRENT_SHA" ]; then
    exit 0
fi

FAILED_SHA="$(cat "$GIT_FAILED_FILE" 2>/dev/null || true)"
if [ "$RETRY_FAILED" -eq 0 ] && [ -n "$FAILED_SHA" ] && [ "$TARGET_SHA" = "$FAILED_SHA" ]; then
    log "Skipping $TARGET_SHA: it previously failed its health check (remove $GIT_FAILED_FILE or use --retry-failed to try again)."
    exit 0
fi

# The health gate cannot test WARP in game mode or while the portal waits for an
# interactive login, so an update promoted now could not be verified. Wait.
if [ -f "$GAME_MODE_MARKER" ] || [ -f "$INTERACTIVE_LOGIN_MARKER" ]; then
    log "Deferring $TARGET_SHA: the health gate cannot test WARP in game mode or while an interactive login is pending."
    exit 0
fi

TARBALL="$WORK/repo.tar.gz"
if ! github_curl "$GITHUB_URL/$GITHUB_REPO/archive/$TARGET_SHA.tar.gz" -o "$TARBALL" 2>/dev/null; then
    log "WARNING: failed to download the archive of $TARGET_SHA."
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
# Keep this the same list, in the same order, as FILES in sync_to_router.sh minus
# those three Mac-only files; tests/test_sync.py checks it.
DEPLOY_FILES="paths.sh lock.sh defaults.sh usque-rs warp_clients.txt login.sh tunnel.sh stop_tunnel.sh game_mode.sh monitor_game_network.sh configure_wifi.sh configure_dns.sh refresh_blinkit_dns.sh google_wan_policy.sh google_service_ranges.txt google_domains.txt configure_lan_ipv6.sh ensure_network.sh diagnose.sh collect_diagnostics.sh dns_flow.sh rotate_logs.sh install_cron_pipeline.sh bootstrap_router.sh download_emergency_diagnostics.sh rotate_tunnel_ip.sh firewall_hook.sh install_firewall_hook.sh promote_staged.sh measure_load_latency.sh fetch_usque_rs.sh update_from_git.sh README.md"

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

# Restart the tunnel a promotion stopped, under the maintenance lock. Started
# outside it, a health tick could find the client half started, stop it and
# start its own, and each start's cleanup then killed the other's client. A
# lock that stays busy means its holder is repairing the tunnel already; the
# gate waits for it.
restart_stopped_tunnel() {
    [ "$WAS_RUNNING" -eq 1 ] || return 0
    if ! acquire_maintenance_lock "$UPDATE_LOCK_WAIT"; then
        log "Leaving the tunnel restart to $MAINTENANCE_LOCK_BUSY, which holds the maintenance lock."
        return 0
    fi
    if ! pidof usque-rs >/dev/null 2>&1; then
        sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    fi
    release_maintenance_lock
}

log "Promoting commit $TARGET_SHA from $GITHUB_REPO@$DEPLOY_BRANCH."
if ! sh "$STAGE/promote_staged.sh" "$DIR" "$UPDATE_LOCK_WAIT" >> "$LOG_FILE" 2>&1; then
    log "ERROR: promotion of $TARGET_SHA failed."
    exit 1
fi

restart_stopped_tunnel

# Health gate: 0 means WARP was tested and works, 75 that it could not be
# tested, anything else that the check failed. Only 0 keeps the update.
GATE_STATUS=0
ROUTER_SCRIPT_TRIGGER=gate sh "$DIR/ensure_network.sh" >> "$LOG_FILE" 2>&1 || GATE_STATUS=$?
if [ "$GATE_STATUS" -eq 0 ]; then
    printf '%s\n' "$TARGET_SHA" > "$DEPLOY_COMMIT_FILE"
    rm -f "$GIT_FAILED_FILE"
    sync
    log "Update to $TARGET_SHA succeeded and passed the health check."
    exit 0
fi

if [ "$GATE_STATUS" -eq 75 ]; then
    log "WARNING: the health check could not test WARP after promoting $TARGET_SHA; rolling back to try again on a later run."
else
    printf '%s\n' "$TARGET_SHA" > "$GIT_FAILED_FILE"
    log "ERROR: health check failed after promoting $TARGET_SHA; rolling back."
fi
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
restart_stopped_tunnel
sh "$DIR/ensure_network.sh" >> "$LOG_FILE" 2>&1 || true
log "Rolled back from $TARGET_SHA to ${CURRENT_SHA:-previous state}."
exit 1

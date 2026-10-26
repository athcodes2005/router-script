#!/bin/sh
# Fetch the verified usque-rs ARM64 musl binary from the usque-rs-openwrt
# GitHub Releases page.
#
# Modes:
#   ./fetch_usque_rs.sh --download-only   (Mac or router: download & verify into $DIR/usque-rs if missing or outdated)
#   ./fetch_usque_rs.sh                   (Router: check release, back up to usque-rs-upstream-v0.1.0, promote under lock, restart WARP, and roll back if health check fails)

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"
LOG_FILE="$(prepare_log_file maintenance)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi
. "$DIR/defaults.sh"

DOWNLOAD_ONLY=0
case "${1:-}" in
    --download-only) DOWNLOAD_ONLY=1 ;;
esac

GITHUB_Download_Base="${USQUE_DOWNLOAD_BASE_URL:-https://github.com/$USQUE_REPO/releases}"
if [ "$USQUE_RELEASE_TAG" = "latest" ]; then
    RELEASE_URL="$GITHUB_Download_Base/latest/download"
else
    RELEASE_URL="$GITHUB_Download_Base/download/$USQUE_RELEASE_TAG"
fi

ARCHIVE_URL="$RELEASE_URL/$USQUE_ASSET_NAME"
SHA_URL="$ARCHIVE_URL.sha256"
LOCK_WAIT="${UPDATE_LOCK_WAIT:-30}"

log() {
    printf '%s - [usque-fetch] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

WORK="$(mktemp -d /tmp/router-usque-fetch.XXXXXX)"
cleanup() {
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' HUP PIPE

fetch_url() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
            curl -fsSL --connect-timeout 5 --max-time 60 -K - "$@"
    else
        curl -fsSL --connect-timeout 5 --max-time 60 "$@"
    fi
}

if ! fetch_url "$SHA_URL" -o "$WORK/asset.sha256" 2>/dev/null; then
    if [ "$DOWNLOAD_ONLY" -eq 1 ] && [ -f "$DIR/usque-rs" ]; then
        exit 0
    fi
    log "WARNING: could not fetch $SHA_URL (release may still be building)."
    exit 0
fi

EXPECTED_ARCHIVE_SHA="$(awk '{print $1}' "$WORK/asset.sha256" | head -n 1)"
case "$EXPECTED_ARCHIVE_SHA" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *)
        log "WARNING: invalid SHA-256 in $SHA_URL."
        exit 0 ;;
esac

RECORDED_ARCHIVE_SHA="$(cat "$DIR/.usque_release_sha" 2>/dev/null || true)"
if [ -f "$DIR/usque-rs" ] && [ "$EXPECTED_ARCHIVE_SHA" = "$RECORDED_ARCHIVE_SHA" ]; then
    exit 0
fi

if ! fetch_url "$ARCHIVE_URL" -o "$WORK/$USQUE_ASSET_NAME" 2>/dev/null; then
    log "WARNING: failed to download $ARCHIVE_URL."
    exit 1
fi

ACTUAL_ARCHIVE_SHA="$(file_sha256 "$WORK/$USQUE_ASSET_NAME")"
if [ "$ACTUAL_ARCHIVE_SHA" != "$EXPECTED_ARCHIVE_SHA" ]; then
    log "ERROR: SHA-256 mismatch for $USQUE_ASSET_NAME (expected $EXPECTED_ARCHIVE_SHA, got $ACTUAL_ARCHIVE_SHA)."
    exit 1
fi

mkdir -p "$WORK/extracted"
tar -xzf "$WORK/$USQUE_ASSET_NAME" -C "$WORK/extracted"
if [ ! -f "$WORK/extracted/usque-rs" ]; then
    log "ERROR: archive $USQUE_ASSET_NAME did not contain usque-rs."
    exit 1
fi
chmod 755 "$WORK/extracted/usque-rs"

NEW_BIN_SHA="$(file_sha256 "$WORK/extracted/usque-rs")"
CURRENT_BIN_SHA=
if [ -f "$DIR/usque-rs" ]; then
    CURRENT_BIN_SHA="$(file_sha256 "$DIR/usque-rs")"
fi

if [ "$NEW_BIN_SHA" = "$CURRENT_BIN_SHA" ]; then
    printf '%s\n' "$EXPECTED_ARCHIVE_SHA" > "$DIR/.usque_release_sha"
    exit 0
fi

if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
    if [ -f "$DIR/usque-rs" ] && [ ! -f "$DIR/usque-rs-upstream-v0.1.0" ]; then
        cp -p "$DIR/usque-rs" "$DIR/usque-rs-upstream-v0.1.0"
    fi
    cp "$WORK/extracted/usque-rs" "$DIR/usque-rs.new"
    chmod 755 "$DIR/usque-rs.new"
    mv "$DIR/usque-rs.new" "$DIR/usque-rs"
    printf '%s\n' "$EXPECTED_ARCHIVE_SHA" > "$DIR/.usque_release_sha"
    log "Downloaded usque-rs ($NEW_BIN_SHA) from $USQUE_REPO@$USQUE_RELEASE_TAG."
    exit 0
fi

# On the router: verify the binary runs on this architecture before taking the lock.
if ! "$WORK/extracted/usque-rs" nativetun --help >/dev/null 2>&1; then
    log "ERROR: downloaded usque-rs failed 'nativetun --help' check; aborting."
    exit 1
fi

MAINTENANCE_LOCK_NAME=fetch_usque_rs.sh
. "$DIR/lock.sh"
if ! acquire_maintenance_lock "$LOCK_WAIT"; then
    log "Skipping binary update: $MAINTENANCE_LOCK_BUSY holds the maintenance lock."
    exit 75
fi

install_and_verify() {
    WAS_RUNNING=0
    if pidof usque-rs >/dev/null 2>&1; then
        WAS_RUNNING=1
        sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    fi

    if [ -f "$DIR/usque-rs" ]; then
        cp -p "$DIR/usque-rs" "$DIR/usque-rs-upstream-v0.1.0.new"
        chmod 755 "$DIR/usque-rs-upstream-v0.1.0.new"
        mv "$DIR/usque-rs-upstream-v0.1.0.new" "$DIR/usque-rs-upstream-v0.1.0"
    fi

    cp "$WORK/extracted/usque-rs" "$DIR/usque-rs.new"
    chmod 755 "$DIR/usque-rs.new"
    mv "$DIR/usque-rs.new" "$DIR/usque-rs"
    sync

    if [ "$WAS_RUNNING" -eq 1 ]; then
        sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || return 1
    fi
    return 0
}

log "Installing new usque-rs ($NEW_BIN_SHA) from $USQUE_REPO@$USQUE_RELEASE_TAG."
INSTALLED_OK=0
if install_and_verify; then
    INSTALLED_OK=1
fi
release_maintenance_lock

if [ "$INSTALLED_OK" -eq 1 ] && sh "$DIR/ensure_network.sh" >> "$LOG_FILE" 2>&1; then
    printf '%s\n' "$EXPECTED_ARCHIVE_SHA" > "$DIR/.usque_release_sha"
    sync
    log "Updated usque-rs ($NEW_BIN_SHA) and passed the health check."
    exit 0
fi

log "ERROR: usque-rs ($NEW_BIN_SHA) failed startup or health check; rolling back to previous binary."
if [ -f "$DIR/usque-rs-upstream-v0.1.0" ] && acquire_maintenance_lock "$LOCK_WAIT"; then
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    cp -p "$DIR/usque-rs-upstream-v0.1.0" "$DIR/usque-rs.new"
    chmod 755 "$DIR/usque-rs.new"
    mv "$DIR/usque-rs.new" "$DIR/usque-rs"
    sync
    sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    release_maintenance_lock
fi
sh "$DIR/ensure_network.sh" >> "$LOG_FILE" 2>&1 || true
exit 1

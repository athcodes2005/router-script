#!/bin/sh
# Runs on the router from the stage directory that sync_to_router.sh filled:
# checks every staged file against the manifest, then stops the tunnel and
# moves the files into place under the maintenance lock, which this process
# owns for the whole step. Nothing moves unless every file checks out, and a
# dropped SSH connection cannot stop the moves halfway: hangups and broken pipes
# are ignored, and nothing here stops on a failed write. A staged file that
# already matches the installed one is dropped, and if none differs the tunnel
# is not stopped: a wiki-only commit or a repeated sync used to interrupt WARP
# for nothing.
# Usage: sh promote_staged.sh PROJECT_DIR [LOCK_WAIT_SECONDS]

trap '' HUP PIPE

STAGE="$(cd "$(dirname "$0")" && pwd)"
DIR="$1"
LOCK_WAIT="${2:-30}"
# shellcheck disable=SC2034 # lock.sh records it as the owner's name.
MAINTENANCE_LOCK_NAME=sync_to_router.sh

log() {
    printf '%s\n' "$*"
}

cd "$STAGE" || exit 1
if ! sha256sum -c .manifest >/dev/null 2>&1; then
    log "ERROR: the staged files do not match what was sent; nothing was promoted."
    exit 1
fi

. "$STAGE/lock.sh"
if ! acquire_maintenance_lock "$LOCK_WAIT"; then
    log "ERROR: $MAINTENANCE_LOCK_BUSY holds the maintenance lock; nothing was promoted."
    exit 75
fi
trap 'release_maintenance_lock' EXIT

CHANGED=0
while read -r HASH FILE; do
    [ -n "$HASH" ] || continue
    cmp -s "$STAGE/$FILE" "$DIR/$FILE" 2>/dev/null || CHANGED=$((CHANGED + 1))
done < .manifest

if [ "$CHANGED" -eq 0 ]; then
    log "Every staged file already matches the installed one; the tunnel keeps running."
else
    log "Every staged file checks out; promoting the $CHANGED that differ."
    if pidof usque-rs >/dev/null 2>&1; then
        log "Tunnel is running. Stopping before promotion."
        sh "$DIR/stop_tunnel.sh"
    fi
fi

# The manifest lists the sourced helpers first, so a script that starts
# meanwhile never finds a new caller next to an old helper (it then finds the
# lock held and changes nothing).
FAILED=
while read -r HASH FILE; do
    [ -n "$HASH" ] || continue
    if cmp -s "$STAGE/$FILE" "$DIR/$FILE" 2>/dev/null; then
        rm -f "$STAGE/$FILE"
    else
        mv "$STAGE/$FILE" "$DIR/$FILE" || FAILED="$FAILED $FILE"
    fi
done < .manifest
rm -f .manifest
cd "$DIR" || exit 1
rmdir "$STAGE" 2>/dev/null || true
chmod 755 ./*.sh
[ ! -f ./usque-rs ] || chmod 755 ./usque-rs
[ ! -f ./.env ] || chmod 600 ./.env
[ ! -f ./config.json ] || chmod 600 ./config.json
# A power cut seconds after a deploy must not leave zero-length files.
sync

if [ -n "$FAILED" ]; then
    log "ERROR: these files could not be promoted:$FAILED"
    exit 1
fi
[ "$CHANGED" -eq 0 ] || log "Promoted the staged files."

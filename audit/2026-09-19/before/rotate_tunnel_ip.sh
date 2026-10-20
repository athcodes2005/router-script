#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$DIR/config.json"
BACKUP_FILE="$DIR/config.json.previous"
BACKUP_TEMP="$BACKUP_FILE.tmp.$$"
LOCK_DIR="$DIR/.ensure_network.lock"
WAS_RUNNING=0
BACKUP_CREATED=0

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file maintenance)"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log "Rotating Cloudflare WARP IP to bypass blocks..."

WAIT_COUNT=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ "$WAIT_COUNT" -ge 30 ]; then
        log "ERROR: Timed out waiting for the network health-check lock."
        exit 1
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

cleanup() {
    STATUS=$?
    trap - EXIT INT TERM

    if [ "$STATUS" -ne 0 ] && [ "$BACKUP_CREATED" -eq 1 ] && [ -f "$BACKUP_FILE" ]; then
        log "Restoring the previous WARP registration after an incomplete rotation."
        sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        rm -f "$CONFIG_FILE"
        mv "$BACKUP_FILE" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        if [ "$WAS_RUNNING" -eq 1 ]; then
            sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        fi
    fi

    rm -f "$BACKUP_TEMP"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    exit "$STATUS"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -e "$BACKUP_FILE" ]; then
    log "ERROR: $BACKUP_FILE already exists; refusing to overwrite possible recovery state."
    exit 1
fi

if pidof usque-rs >/dev/null 2>&1; then
    WAS_RUNNING=1
fi

# Stop the currently running tunnel
if [ -f "$DIR/stop_tunnel.sh" ]; then
    log "Stopping active tunnel..."
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
fi

# Remove the existing registration
if [ -f "$CONFIG_FILE" ]; then
    log "Backing up and removing the existing Cloudflare device registration..."
    cp "$CONFIG_FILE" "$BACKUP_TEMP"
    chmod 600 "$BACKUP_TEMP"
    mv "$BACKUP_TEMP" "$BACKUP_FILE"
    BACKUP_CREATED=1
    rm -f "$CONFIG_FILE"
fi

# Restart the tunnel (which automatically triggers a fresh registration in tunnel.sh)
log "Starting tunnel to fetch a fresh pair of IP addresses..."
if sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 \
    && pidof "usque-rs" >/dev/null 2>&1 \
    && [ "$(curl -4 -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null || true)" = "204" ] \
    && [ "$(curl -6 -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null || true)" = "204" ]; then
    rm -f "$BACKUP_FILE"
    BACKUP_CREATED=0
    log "SUCCESS: IP rotation complete. You have a fresh Cloudflare connection."
else
    log "ERROR: The new registration failed; cleanup will restore the previous configuration."
    exit 1
fi

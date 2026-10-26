#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
CONFIG_FILE="$DIR/config.json"
BACKUP_FILE="$DIR/config.json.previous"
BACKUP_TEMP="$BACKUP_FILE.tmp.$$"
WARP_TRACE_URL_V4="${WARP_TRACE_URL_V4:-https://1.1.1.1/cdn-cgi/trace}"
WARP_TRACE_URL_V6="${WARP_TRACE_URL_V6:-https://[2606:4700:4700::1111]/cdn-cgi/trace}"
WAS_RUNNING=0
BACKUP_CREATED=0

# .env first, so LOG_DIR / DIAGNOSTICS_DIR overrides reach paths.sh.
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

. "$DIR/paths.sh"
. "$DIR/defaults.sh"

LOG_FILE="$(prepare_log_file maintenance)"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# The new identity must carry traffic itself: probe through tun0 and require
# Cloudflare's trace to report WARP. Google IPv4 bypasses WARP, and only the
# trace says which identity carried a request, so Google cannot validate it.
warp_trace_ok() {
    curl "$1" -g -sS --interface "$TUN_IF" --connect-timeout 5 --max-time 15 "$2" 2>/dev/null |
        grep -Eq '^warp=(on|plus)$'
}

log "Rotating Cloudflare WARP IP to bypass blocks..."

. "$DIR/lock.sh"
if ! acquire_maintenance_lock 30; then
    log "ERROR: $MAINTENANCE_LOCK_BUSY holds the maintenance lock; not rotating."
    exit 1
fi

cleanup() {
    STATUS=$?
    trap - EXIT HUP PIPE INT TERM

    if [ "$STATUS" -ne 0 ] && [ "$BACKUP_CREATED" -eq 1 ] && [ -f "$BACKUP_FILE" ]; then
        # After an SSH drop the terminal is gone and tee fails; under set -e
        # that would abort the restore and leave the lock behind.
        log "Restoring the previous WARP registration after an incomplete rotation." || true
        sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        rm -f "$CONFIG_FILE"
        mv "$BACKUP_FILE" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        if [ "$WAS_RUNNING" -eq 1 ]; then
            sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        fi
    fi

    rm -f "$BACKUP_TEMP"
    release_maintenance_lock
    exit "$STATUS"
}

trap cleanup EXIT
# After an SSH drop the shell reports a child killed by the hangup on the
# closed terminal; that raises SIGPIPE, which must restore the registration too.
trap 'exit 129' HUP
trap 'exit 141' PIPE
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
    && warp_trace_ok -4 "$WARP_TRACE_URL_V4" \
    && warp_trace_ok -6 "$WARP_TRACE_URL_V6"; then
    rm -f "$BACKUP_FILE"
    BACKUP_CREATED=0
    log "SUCCESS: IP rotation complete. You have a fresh Cloudflare connection."
else
    log "ERROR: The new registration failed; cleanup will restore the previous configuration."
    exit 1
fi

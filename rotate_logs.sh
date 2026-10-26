#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-1048576}"
KEEP_ROTATIONS="${KEEP_ROTATIONS:-3}"
ROTATION_TMP=""

# .env first, so LOG_DIR / DIAGNOSTICS_DIR overrides reach paths.sh.
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

. "$DIR/paths.sh"
. "$DIR/defaults.sh"

LOG_FILE="$(prepare_log_file maintenance)"

cleanup() {
    [ -n "$ROTATION_TMP" ] && rm -f "$ROTATION_TMP"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

rotate_file() {
    FILE="$1"

    [ -f "$FILE" ] || return 0

    SIZE="$(wc -c < "$FILE" | tr -d ' ')"
    [ "$SIZE" -lt "$MAX_LOG_BYTES" ] && return 0

    INDEX="$KEEP_ROTATIONS"
    while [ "$INDEX" -gt 1 ]; do
        PREV=$((INDEX - 1))
        [ -f "$FILE.$PREV" ] && mv "$FILE.$PREV" "$FILE.$INDEX"
        INDEX=$PREV
    done

    # Keep only the most recent bounded tail. Copying an already oversized log
    # would preserve the entire file and can rapidly exhaust router flash.
    ROTATION_TMP="$FILE.1.tmp.$$"
    tail -c "$MAX_LOG_BYTES" "$FILE" > "$ROTATION_TMP"
    mv "$ROTATION_TMP" "$FILE.1"
    ROTATION_TMP=""
    : > "$FILE"
    log "Rotated $(basename "$FILE") at ${SIZE} bytes."
}

rotate_file "$(prepare_log_file login)"
rotate_file "$(prepare_log_file tunnel)"
rotate_file "$(prepare_log_file dns)"
rotate_file "$(prepare_log_file ipv6)"
rotate_file "$(prepare_log_file ensure)"
rotate_file "$(prepare_log_file maintenance)"
rotate_file "$(prepare_log_file wifi)"
rotate_file "$(prepare_log_file game_monitor)"
rotate_file "$(prepare_log_file latency)"

if [ "$MAX_DIAGNOSTICS" -gt 0 ] 2>/dev/null; then
    ls -1t "$DIAGNOSTICS_DIR"/diagnostic_*.log 2>/dev/null | sed -n "$((MAX_DIAGNOSTICS + 1)),\$p" | while IFS= read -r OLD_FILE; do
        [ -n "$OLD_FILE" ] && rm -f "$OLD_FILE"
    done
    ls -1t "$DIAGNOSTICS_DIR"/emergency_*.log 2>/dev/null | sed -n "$((MAX_DIAGNOSTICS + 1)),\$p" | while IFS= read -r OLD_FILE; do
        [ -n "$OLD_FILE" ] && rm -f "$OLD_FILE"
    done
fi

log "Log maintenance completed."

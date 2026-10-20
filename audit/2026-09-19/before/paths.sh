#!/bin/sh

if [ -n "${DIR:-}" ]; then
    PROJECT_DIR="$DIR"
elif [ -n "${SCRIPT_DIR:-}" ]; then
    PROJECT_DIR="$SCRIPT_DIR"
else
    PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
DIAGNOSTICS_DIR="${DIAGNOSTICS_DIR:-$PROJECT_DIR/diagnostics}"
PERSISTENT_STORAGE_FALLBACK_PERCENT="${PERSISTENT_STORAGE_FALLBACK_PERCENT:-97}"

PROJECT_USED_PERCENT="$(df -P "$PROJECT_DIR" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
case "$PROJECT_USED_PERCENT" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$PROJECT_USED_PERCENT" -ge "$PERSISTENT_STORAGE_FALLBACK_PERCENT" ]; then
            LOG_DIR="/tmp/router-script/logs"
            DIAGNOSTICS_DIR="/tmp/router-script/diagnostics"
        fi
        ;;
esac

if ! mkdir -p "$LOG_DIR" "$DIAGNOSTICS_DIR" 2>/dev/null; then
    LOG_DIR="/tmp/router-script/logs"
    DIAGNOSTICS_DIR="/tmp/router-script/diagnostics"
    mkdir -p "$LOG_DIR" "$DIAGNOSTICS_DIR"
fi

prepare_log_file() {
    printf '%s\n' "$LOG_DIR/$1.log"
}

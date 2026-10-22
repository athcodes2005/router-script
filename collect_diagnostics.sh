#!/bin/sh

set -eu
# Snapshots record topology, client data and logs: keep them owner-only.
umask 077

DIR="$(cd "$(dirname "$0")" && pwd)"

. "$DIR/paths.sh"
. "$DIR/defaults.sh"

# Use --emergency or -e flag for emergency prefix
PREFIX="diagnostic"
case "${1:-}" in
    --emergency|-e) PREFIX="emergency" ;;
esac

OUTPUT_FILE="$DIAGNOSTICS_DIR/${PREFIX}_$(date '+%Y%m%d_%H%M%S')_$$.log"
CAPTURE_COMPLETE=0

cleanup() {
    if [ "$CAPTURE_COMPLETE" -eq 0 ]; then
        rm -f "$OUTPUT_FILE"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$DIR/diagnose.sh" > "$OUTPUT_FILE" 2>&1
CAPTURE_COMPLETE=1

# Trim old reports of same type
if [ "$MAX_DIAGNOSTICS" -gt 0 ] 2>/dev/null; then
    ls -1t "$DIAGNOSTICS_DIR"/${PREFIX}_*.log 2>/dev/null | sed -n "$((MAX_DIAGNOSTICS + 1)),\$p" | while IFS= read -r OLD_FILE; do
        [ -n "$OLD_FILE" ] && rm -f "$OLD_FILE"
    done
fi

printf '%s\n' "$OUTPUT_FILE"

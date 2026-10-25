#!/bin/sh
# Measure the round trip through WARP while idle, during an upload and during a
# download, to see how much queueing a saturated link adds (F10; compare runs
# with and without WARP_UPLOAD_CODEL). Each sample is the TCP connect time
# to RTT_URL through tun0. Nothing is reconfigured: the only effect is the test
# traffic, up to PHASE_SECONDS each way to Cloudflare's speed test. The
# maintenance lock is held throughout, so a health check cannot restart WARP
# halfway; game mode and rotation wait for it too.
# Usage: sh measure_load_latency.sh [PHASE_SECONDS]

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file latency)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi
. "$DIR/defaults.sh"

PHASE_SECONDS="${1:-20}"
RTT_URL="${RTT_URL:-http://1.1.1.1/cdn-cgi/trace}"
UPLOAD_URL="${UPLOAD_URL:-https://speed.cloudflare.com/__up}"
# The largest download the speed test serves: it refuses 100 MB and more.
DOWNLOAD_URL="${DOWNLOAD_URL:-https://speed.cloudflare.com/__down?bytes=75000000}"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

case "$PHASE_SECONDS" in
    ''|*[!0-9]*) echo "Usage: $0 [PHASE_SECONDS]" >&2; exit 1 ;;
esac
[ "$PHASE_SECONDS" -ge 8 ] || { echo "PHASE_SECONDS must be at least 8." >&2; exit 1; }

if ! pidof usque-rs >/dev/null 2>&1 || ! ip link show dev "$TUN_IF" >/dev/null 2>&1; then
    log "Latency test: WARP is not running; nothing to measure."
    exit 1
fi

. "$DIR/lock.sh"
if ! acquire_maintenance_lock 30; then
    log "Latency test: $MAINTENANCE_LOCK_BUSY holds the maintenance lock; try again later."
    exit 1
fi
WORK="$(mktemp -d /tmp/router-latency.XXXXXX)"
LOAD_PID=
cleanup() {
    [ -z "$LOAD_PID" ] || kill "$LOAD_PID" 2>/dev/null || true
    rm -rf "$WORK"
    release_maintenance_lock
}
trap cleanup EXIT
# After an SSH drop the shell reports a child killed by the hangup on the
# closed terminal; that raises SIGPIPE, which must clean up too.
trap 'exit 129' HUP
trap 'exit 141' PIPE
trap 'exit 130' INT
trap 'exit 143' TERM

# One TCP connect time in milliseconds, or nothing if it failed.
rtt_sample() {
    curl -4 -sS -o /dev/null --interface "$TUN_IF" --connect-timeout 3 --max-time 4 \
        -w '%{time_connect}\n' "$RTT_URL" 2>/dev/null |
        awk '$1 > 0 { printf "%.0f\n", $1 * 1000 }' || true
}

# Samples once a second; prints "min/median/max = A/B/C ms (N samples, M failed)".
rtt_series() {
    : > "$WORK/rtt"
    FAILED=0
    COUNT=0
    while [ "$COUNT" -lt "$1" ]; do
        SAMPLE="$(rtt_sample)"
        if [ -n "$SAMPLE" ]; then
            printf '%s\n' "$SAMPLE" >> "$WORK/rtt"
        else
            FAILED=$((FAILED + 1))
        fi
        COUNT=$((COUNT + 1))
        sleep 1
    done
    sort -n "$WORK/rtt" | awk -v failed="$FAILED" '
        { v[NR] = $1 }
        END {
            if (NR == 0) { printf "no replies (%d failed)", failed; exit }
            printf "min/median/max = %d/%d/%d ms (%d samples, %d failed)",
                v[1], v[int((NR + 1) / 2)], v[NR], NR, failed
        }'
}

mbit() {
    awk '{ printf "%.1f Mbit/s", $1 * 8 / 1000000 }' "$1" 2>/dev/null || echo "unknown speed"
}

# Repeats the download until the phase ends: a fast link finishes one in a few
# seconds. Each transfer logs "HTTP_CODE BYTES". A refused or failed request
# ends the load rather than being retried in a tight loop.
download_load() {
    DEADLINE=$(($(date +%s) + PHASE_SECONDS))
    while :; do
        LEFT=$((DEADLINE - $(date +%s)))
        [ "$LEFT" -gt 0 ] || break
        RESULT="$(curl -4 -sS -o /dev/null --interface "$TUN_IF" --max-time "$LEFT" \
            -w '%{http_code} %{size_download}' "$DOWNLOAD_URL" 2>/dev/null || true)"
        printf '%s\n' "$RESULT" >> "$WORK/down"
        case "$RESULT" in 200\ *) ;; *) break ;; esac
    done
}

# The download rate over the phase, or why nothing was downloaded.
download_rate() {
    awk -v seconds="$PHASE_SECONDS" '
        $1 == 200 { bytes += $2; n++; next }
        { code = $1 }
        END {
            if (bytes == 0) { printf "no download (HTTP %s)", (code == "" ? "none" : code); exit }
            printf "%.1f Mbit/s (%d transfer%s)", bytes * 8 / seconds / 1000000, n, (n == 1 ? "" : "s")
        }' "$WORK/down" 2>/dev/null || echo "unknown speed"
}

CLIENT_PID="$(pidof usque-rs | awk '{ print $1 }')"
# One argument per line; BusyBox's grep -o finds only one of two patterns.
OPTIONS="$(tr '\000' '\n' < "/proc/$CLIENT_PID/cmdline" 2>/dev/null | awk '
    option == "--tun-backpressure" || option == "--upload-codel" { printf "%s%s %s", sep, option, $0; sep = ", " }
    { option = $0 }')"
log "Latency test through $TUN_IF: ${PHASE_SECONDS}s per phase; client $CLIENT_PID (${OPTIONS:-no --tun-backpressure or --upload-codel})."

LOAD_SAMPLES=$((PHASE_SECONDS - 4))
log "Latency idle:     $(rtt_series "$PHASE_SECONDS")."

# An endless upload body, ended by --max-time; curl streams it without buffering.
curl -4 -sS -o /dev/null --interface "$TUN_IF" --max-time "$PHASE_SECONDS" -X POST -T - \
    -w '%{speed_upload}\n' "$UPLOAD_URL" < /dev/zero > "$WORK/up" 2>/dev/null &
LOAD_PID=$!
sleep 2
UPLOAD_RTT="$(rtt_series "$LOAD_SAMPLES")"
wait "$LOAD_PID" 2>/dev/null || true
LOAD_PID=
log "Latency upload:   $UPLOAD_RTT; $(mbit "$WORK/up")."

# Stopping this loop leaves its current curl to end at that transfer's own
# --max-time, within the phase.
: > "$WORK/down"
download_load &
LOAD_PID=$!
sleep 2
DOWNLOAD_RTT="$(rtt_series "$LOAD_SAMPLES")"
wait "$LOAD_PID" 2>/dev/null || true
LOAD_PID=
log "Latency download: $DOWNLOAD_RTT; $(download_rate)."

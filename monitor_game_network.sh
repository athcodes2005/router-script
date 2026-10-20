#!/bin/sh
# Read-only, bounded monitor. PHONE_IP is optional; sleeping clients may ignore ping.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
[ ! -f "$DIR/.env" ] || . "$DIR/.env"
. "$DIR/paths.sh"
MONITOR_LOG="$(prepare_log_file game_monitor)"
DURATION="${DURATION:-2700}"
INTERVAL="${INTERVAL:-5}"
PHONE_IP="${PHONE_IP:-}"
WAN_IF="${WAN_IF:-eth0}"
TUN_IF="${TUN_IF:-tun0}"
PROBE_URL="${PROBE_URL:-https://www.google.com/generate_204}"
MAX_MONITOR_BYTES="${MAX_MONITOR_BYTES:-1048576}"
for VALUE in "$DURATION" "$INTERVAL" "$MAX_MONITOR_BYTES"; do
    case "$VALUE" in ''|*[!0-9]*|0) echo 'Duration, interval and log size must be positive integers.' >&2; exit 1;; esac
done
WORK="$(mktemp -d /tmp/router-game-monitor.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ping_summary() {
    ping -c 2 -W 1 "$1" 2>/dev/null |
        awk '/packets transmitted/ {loss=$0} /round-trip|rtt/ {rtt=$0}
             END {if (rtt == "") print "NO_REPLY"; else print loss "; " rtt}'
}
http_summary() {
    if RESULT="$(curl -4 -sS --interface "$1" --connect-timeout 2 --max-time 3 \
        -o /dev/null -w '%{http_code} %{time_total}' "$PROBE_URL" 2>/dev/null)"; then
        case "$RESULT" in 204\ *) printf 'OK %s\n' "$RESULT";; *) printf 'HTTP_FAIL %s\n' "$RESULT";; esac
    else
        printf 'TRANSPORT_FAIL %s\n' "$RESULT"
    fi
}
write_log() {
    if [ -f "$MONITOR_LOG" ] && [ "$(wc -c < "$MONITOR_LOG")" -ge "$MAX_MONITOR_BYTES" ]; then
        mv "$MONITOR_LOG" "$MONITOR_LOG.1"
    fi
    printf '%s\n' "$*" >> "$MONITOR_LOG"
}
START="$(date +%s)"
DEADLINE=$((START + DURATION))
write_log "=== Monitor started $(date); client=${PHONE_IP:-not_selected}; duration=${DURATION}s ==="
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    SAMPLE_START="$(date +%s)"
    GW_IP="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
    # Parallel probes see approximately the same moment, and cap sample time.
    (if [ -n "$GW_IP" ]; then ping_summary "$GW_IP"; else echo NO_GATEWAY; fi) > "$WORK/gw" &
    GW_PID=$!
    (if [ -n "$PHONE_IP" ]; then ping_summary "$PHONE_IP"; else echo NOT_SELECTED; fi) > "$WORK/phone" &
    PHONE_PID=$!
    http_summary "$WAN_IF" > "$WORK/wan" & WAN_PID=$!
    http_summary "$TUN_IF" > "$WORK/warp" & WARP_PID=$!
    wait "$GW_PID" || true
    wait "$PHONE_PID" || true
    wait "$WAN_PID" || true
    wait "$WARP_PID" || true
    write_log "$(date '+%Y-%m-%d %H:%M:%S') | gateway: $(cat "$WORK/gw") | client: $(cat "$WORK/phone") | WAN: $(cat "$WORK/wan") | WARP: $(cat "$WORK/warp") | load: $(cut -d ' ' -f 1-3 /proc/loadavg)"
    NEXT=$((SAMPLE_START + INTERVAL))
    [ "$NEXT" -le "$DEADLINE" ] || NEXT="$DEADLINE"
    NOW="$(date +%s)"
    if [ "$NEXT" -gt "$NOW" ]; then sleep "$((NEXT - NOW))"; fi
 done
write_log "=== Monitor completed $(date) ==="
printf 'Saved to %s\n' "$MONITOR_LOG"

#!/bin/sh
# Continuous game latency and network monitor
# Runs for 45 minutes (2700s), sampling every 5 seconds.

DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_LOG="${DIR}/logs/game_monitor.log"
DURATION=2700
INTERVAL=5
PHONE_IP="192.168.8.176"
ALT_PHONE_IP="192.168.8.146"
GW_IP="10.1.40.250"

mkdir -p "$(dirname "$MONITOR_LOG")"
echo "=== BGMI Game Network Monitor Started at $(date) ===" | tee -a "$MONITOR_LOG"

ELAPSED=0
while [ "$ELAPSED" -lt "$DURATION" ]; do
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # 1. Ping Gateway
    GW_PING="$(ping -c 2 -W 1 "$GW_IP" 2>/dev/null | awk -F'/' '/round-trip|rtt/ {gsub(/[^0-9.]/, "", $5); print $5}')"
    [ -z "$GW_PING" ] && GW_PING="LOSS"

    # 2. Ping Active Phone
    PHONE_PING="$(ping -c 2 -W 1 "$PHONE_IP" 2>/dev/null | awk -F'/' '/round-trip|rtt/ {gsub(/[^0-9.]/, "", $5); print $5}')"
    if [ -z "$PHONE_PING" ]; then
        PHONE_PING="$(ping -c 2 -W 1 "$ALT_PHONE_IP" 2>/dev/null | awk -F'/' '/round-trip|rtt/ {gsub(/[^0-9.]/, "", $5); print $5}')"
        [ -z "$PHONE_PING" ] && PHONE_PING="LOSS"
    fi

    # 3. Direct WAN HTTP 204 Probe
    WAN_TIME="$(curl -4 -sS --interface eth0 --connect-timeout 2 --max-time 3 -o /dev/null -w '%{time_total}' https://www.google.com/generate_204 2>/dev/null || echo 'FAIL')"

    # 4. Check BGMI UDP 20000 flows
    GAME_FLOWS="$(grep -c 'dport=20000' /proc/net/nf_conntrack 2>/dev/null || echo 0 | tr -d ' \n')"
    [ -z "$GAME_FLOWS" ] && GAME_FLOWS=0

    # Format log line
    LOG_LINE="${TIMESTAMP} | GW: ${GW_PING} ms | Phone: ${PHONE_PING} ms | WAN_204: ${WAN_TIME} s | BGMI_UDP_Flows: ${GAME_FLOWS}"
    
    # Check for anomalies
    ANOMALY=""
    case "$GW_PING" in
        LOSS) ANOMALY="[ALERT: Gateway Loss]" ;;
        *)
            if awk -v p="$GW_PING" 'BEGIN {exit !(p > 10)}' 2>/dev/null; then
                ANOMALY="[ALERT: High Gateway Ping ${GW_PING}ms]"
            fi
            ;;
    esac

    case "$PHONE_PING" in
        LOSS) ANOMALY="${ANOMALY} [ALERT: Phone Wi-Fi Loss]" ;;
        *)
            if awk -v p="$PHONE_PING" 'BEGIN {exit !(p > 30)}' 2>/dev/null; then
                ANOMALY="${ANOMALY} [ALERT: Wi-Fi Jitter ${PHONE_PING}ms]"
            fi
            ;;
    esac

    if [ "$WAN_TIME" = "FAIL" ]; then
        ANOMALY="${ANOMALY} [ALERT: WAN Probe Failed]"
    fi

    if [ -n "$ANOMALY" ]; then
        echo "${LOG_LINE} ${ANOMALY}" | tee -a "$MONITOR_LOG"
    else
        echo "$LOG_LINE" >> "$MONITOR_LOG"
    fi

    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "=== BGMI Game Network Monitor Completed at $(date) ===" | tee -a "$MONITOR_LOG"

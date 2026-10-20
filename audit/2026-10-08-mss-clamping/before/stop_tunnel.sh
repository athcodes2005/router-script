#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$DIR/usque-rs"
CONFIG_FILE="$DIR/config.json"
ENV_FILE="$DIR/.env"
BLOCKLIST="$DIR/blocked_sites.txt"
WARP_CLIENTS_FILE="$DIR/warp_clients.txt"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file tunnel)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

WAN_IF="${WAN_IF:-eth0}"
LAN_IF="${LAN_IF:-br-lan}"
LAN_SUBNET="${LAN_SUBNET:-192.168.8.0/24}"
TUN_IF="${TUN_IF:-tun0}"
CAMPUS_NETS="${CAMPUS_NETS:-10.0.0.0/8 103.21.124.0/22}"
CAMPUS_ROUTES_FILE="${CAMPUS_ROUTES_FILE:-/tmp/router-script-campus-host-routes}"
DIRECT_PUBLIC_ROUTES_FILE="${DIRECT_PUBLIC_ROUTES_FILE:-/tmp/router-script-direct-public-host-routes}"
GAME_SESSION_ROUTES_FILE="${GAME_SESSION_ROUTES_FILE:-/tmp/router-script-game-session-host-routes}"
GAME_POLICY_TABLE="${GAME_POLICY_TABLE:-101}"
GAME_POLICY_PRIORITY="${GAME_POLICY_PRIORITY:-700}"
GAME_POLICY_MARK="${GAME_POLICY_MARK:-0x40000}"
GAME_POLICY_MASK="${GAME_POLICY_MASK:-0xf0000}"
GAME_SESSION_PORTS="${GAME_SESSION_PORTS:-9339}"
WARP_ENDPOINTS="${WARP_ENDPOINTS:-162.159.198.1 162.159.192.1}"
WARP_CLIENT_TABLE="${WARP_CLIENT_TABLE:-100}"
WARP_READY_FILE="${WARP_READY_FILE:-/tmp/router-script-warp-ready}"

if [ -f "$CONFIG_FILE" ]; then
    CONFIG_ENDPOINT="$(jsonfilter -i "$CONFIG_FILE" -e '@.endpoint_v4' 2>/dev/null || true)"
    case "$CONFIG_ENDPOINT" in
        *.*.*.*) WARP_ENDPOINTS="$WARP_ENDPOINTS $CONFIG_ENDPOINT" ;;
    esac
fi

echo "[INFO] Stopping tunnel service at $(date)" >> "$LOG_FILE"

# 1. Kill the process
if pidof "$(basename "$EXECUTABLE")" >/dev/null 2>&1; then
    killall "$(basename "$EXECUTABLE")"
    WAIT_COUNT=0
    while pidof "$(basename "$EXECUTABLE")" >/dev/null 2>&1 && [ "$WAIT_COUNT" -lt 10 ]; do
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    if pidof "$(basename "$EXECUTABLE")" >/dev/null 2>&1; then
        echo "[WARNING] Tunnel process did not exit after ${WAIT_COUNT}s; forcing shutdown." >> "$LOG_FILE"
        killall -9 "$(basename "$EXECUTABLE")" 2>/dev/null || true
    fi
    echo "[SUCCESS] Stopped $(basename "$EXECUTABLE") process." >> "$LOG_FILE"
    echo "Tunnel process stopped."
else
    echo "[INFO] Tunnel process is not running." >> "$LOG_FILE"
    echo "Tunnel process is not running."
fi
rm -f "$WARP_READY_FILE"

# 2. Cleanup routing rules
echo "[INFO] Reverting routing table changes..." >> "$LOG_FILE"

# Remove IPv6 default through tun0
ip -6 route del default dev "$TUN_IF" metric 5 2>/dev/null

# Remove IPv4 default through tun0; the WAN default remains as fallback.
ip -4 route del default dev "$TUN_IF" metric 5 2>/dev/null

# Remove blocklist routes
if [ -f "$BLOCKLIST" ]; then
    grep -v '^\s*#' "$BLOCKLIST" | grep -v '^\s*$' | while IFS= read -r DEST; do
        DEST="$(echo "$DEST" | tr -d '[:space:]')"
        [ -n "$DEST" ] && ip route del "$DEST" dev "$TUN_IF" 2>/dev/null
    done
fi

# Remove per-client WARP policy rules and their routing table.
if [ -f "$WARP_CLIENTS_FILE" ]; then
    grep -v '^\s*#' "$WARP_CLIENTS_FILE" | grep -v '^\s*$' | while IFS= read -r CLIENT; do
        CLIENT="$(echo "$CLIENT" | tr -d '[:space:]')"
        [ -z "$CLIENT" ] && continue
        while ip rule del from "$CLIENT" table "$WARP_CLIENT_TABLE" 2>/dev/null; do :; done
    done
fi
ip route flush table "$WARP_CLIENT_TABLE" 2>/dev/null
while ip rule del priority "$GAME_POLICY_PRIORITY" fwmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" table "$GAME_POLICY_TABLE" 2>/dev/null; do :; done
ip route del "$LAN_SUBNET" dev "$LAN_IF" table "$GAME_POLICY_TABLE" 2>/dev/null || true
ip route del default via "$(ip route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')" dev "$WAN_IF" table "$GAME_POLICY_TABLE" 2>/dev/null || true
ip route flush cache 2>/dev/null

# Remove route overrides from tunnel startup
ip route del "$LAN_SUBNET" dev "$LAN_IF" metric 1 2>/dev/null
for NET in $CAMPUS_NETS; do
    ip route del "$NET" 2>/dev/null
done
if [ -f "$CAMPUS_ROUTES_FILE" ]; then
    while IFS= read -r ROUTE; do
        [ -n "$ROUTE" ] && ip route del "$ROUTE" 2>/dev/null || true
    done < "$CAMPUS_ROUTES_FILE"
    rm -f "$CAMPUS_ROUTES_FILE"
fi
if [ -f "$DIRECT_PUBLIC_ROUTES_FILE" ]; then
    while IFS= read -r ROUTE; do
        [ -n "$ROUTE" ] && ip route del "$ROUTE" 2>/dev/null || true
    done < "$DIRECT_PUBLIC_ROUTES_FILE"
    rm -f "$DIRECT_PUBLIC_ROUTES_FILE"
fi
if [ -f "$GAME_SESSION_ROUTES_FILE" ]; then
    while IFS= read -r ROUTE; do
        [ -n "$ROUTE" ] && ip route del "$ROUTE" 2>/dev/null || true
    done < "$GAME_SESSION_ROUTES_FILE"
    rm -f "$GAME_SESSION_ROUTES_FILE"
fi
for ENDPOINT in $WARP_ENDPOINTS; do
    ip route del "$ENDPOINT" 2>/dev/null
done

# Clean up MASQUERADE rules
while iptables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null
done
while ip6tables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null; do
    ip6tables -t nat -D POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null
done

# Clean up FORWARD rules
while iptables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null
done
while iptables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
done
while ip6tables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null; do
    ip6tables -D FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null
done
while ip6tables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
    ip6tables -D FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
done
while iptables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
    iptables -t mangle -D FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
done
while ip6tables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
    ip6tables -t mangle -D FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
done
while iptables -t mangle -C PREROUTING -j GAME_SESSION_POLICY 2>/dev/null; do
    iptables -t mangle -D PREROUTING -j GAME_SESSION_POLICY 2>/dev/null
done
if iptables -t mangle -L GAME_SESSION_POLICY >/dev/null 2>&1; then
    iptables -t mangle -F GAME_SESSION_POLICY 2>/dev/null || true
    iptables -t mangle -X GAME_SESSION_POLICY 2>/dev/null || true
fi

# Restore IPv6 forwarding state
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1

echo "[SUCCESS] Routing rules and IPv6 state reverted." >> "$LOG_FILE"
echo "Routing reverted to default WAN."

exit 0

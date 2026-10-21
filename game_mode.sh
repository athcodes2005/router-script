#!/bin/sh
# Toggle low-latency "game mode": public IPv4 uses direct campus WAN instead of
# WARP. Captive portal must already be authenticated. Campus 10/8 stays direct
# either way. Use this for competitive shooters; disable afterward for full
# WARP dual-stack.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file ensure)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

MARKER="${GAME_MODE_MARKER:-/tmp/router-script-game-mode}"
WAN_IF="${WAN_IF:-eth0}"
LAN_IF="${LAN_IF:-br-lan}"
TUN_IF="${TUN_IF:-tun0}"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

usage() {
    echo "Usage: $0 on|off|status"
    exit 1
}

[ "$#" -ge 1 ] || usage
CMD="$1"

# Serialize policy changes with the watchdog. Status remains read-only.
case "$CMD" in
    on|off)
        LOCK_DIR="$DIR/.ensure_network.lock"
        WAIT_COUNT=0
        until mkdir "$LOCK_DIR" 2>/dev/null; do
            [ "$WAIT_COUNT" -lt 30 ] || { log "game_mode: maintenance lock busy"; exit 1; }
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
        trap 'exit 129' HUP
trap 'exit 130' INT
        trap 'exit 143' TERM
        ;;
    status) ;;
    *) usage ;;
esac

case "$CMD" in
    status)
        if [ -f "$MARKER" ]; then
            echo "game_mode=on"
        else
            echo "game_mode=off"
        fi
        ip -4 route show default
        curl -4 -sS --max-time 4 -o /dev/null -w "default_path http=%{http_code} t=%{time_total}\n" \
            https://www.google.com/generate_204 2>/dev/null || echo "default_path probe failed"
        curl -4 -sS --interface "$WAN_IF" --max-time 4 -o /dev/null -w "direct_wan  http=%{http_code} t=%{time_total}\n" \
            https://www.google.com/generate_204 2>/dev/null || echo "direct_wan probe failed"
        ;;
    on)
        # Prefer eth0 default over tun0 (metrics: lower wins).
        # Keep tun0 present so disabling is fast; just demote it.
        if ! ip -4 route show default dev "$WAN_IF" 2>/dev/null | grep -q default; then
            GW="$(ip -4 route show default dev "$TUN_IF" 2>/dev/null | awk '/via/ {print $3; exit}')"
            [ -n "$GW" ] || GW="$(ip -4 route show dev "$WAN_IF" 2>/dev/null | awk '/via/ {print $3; exit}')"
            # Fall back to current non-tun default gateway if any.
            [ -n "$GW" ] || GW="$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}')"
            if [ -z "$GW" ]; then
                # Last resort: WAN interface gateway from main table eth0 routes.
                GW="$(ip -4 route get 10.200.1.11 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
            fi
            if [ -n "$GW" ]; then
                ip route replace default via "$GW" dev "$WAN_IF" metric 1
            else
                log "game_mode on: could not determine WAN gateway"
                exit 1
            fi
        else
            # Existing WAN default: force metric 1 (beats tun0 metric 5).
            GW="$(ip -4 route show default dev "$WAN_IF" 2>/dev/null | awk '/via/ {print $3; exit}')"
            if [ -n "$GW" ]; then
                ip route replace default via "$GW" dev "$WAN_IF" metric 1
            fi
        fi
        # Demote WARP default so it is not selected.
        if ip -4 route show default dev "$TUN_IF" 2>/dev/null | grep -q default; then
            ip route del default dev "$TUN_IF" 2>/dev/null || true
            ip route add default dev "$TUN_IF" metric 50 2>/dev/null || true
        fi
        # Demote WARP IPv6 default and reject LAN->tun0 IPv6 forwarding during game mode
        # to prevent games from blackholing match UDP packets over unreplied IPv6/NAT64.
        if ip -6 route show default dev "$TUN_IF" 2>/dev/null | grep -q default; then
            ip -6 route del default dev "$TUN_IF" 2>/dev/null || true
            ip -6 route add default dev "$TUN_IF" metric 50 2>/dev/null || true
        fi
        ip6tables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j REJECT 2>/dev/null || \
            ip6tables -I FORWARD -i "$LAN_IF" -o "$TUN_IF" -j REJECT 2>/dev/null || true

        # Enable AAAA filtering in dnsmasq so game clients use IPv4 directly
        uci set dhcp.@dnsmasq[0].filter_aaaa='1'
        uci commit dhcp
        /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true

        # Pause aggressive tunnel restarts while gaming: ensure_network still
        # repairs WAN/DNS/portal, but must not yank the default back to tun0.
        printf 'on\n' > "$MARKER"
        log "game_mode ON: public IPv4 prefers $WAN_IF (WARP demoted, IPv6 isolated, filter_aaaa=1)."
        "$0" status
        ;;
    off)
        rm -f "$MARKER"
        # Restore normal full-tunnel preference and IPv6.
        while ip6tables -D FORWARD -i "$LAN_IF" -o "$TUN_IF" -j REJECT 2>/dev/null; do :; done
        uci set dhcp.@dnsmasq[0].filter_aaaa='0'
        uci commit dhcp
        /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true

        # Save the gateway before removing metric 1: it may be the only WAN
        # default after a DHCP renewal while game mode was active.
        GW="$(ip -4 route show default dev "$WAN_IF" 2>/dev/null | awk '/via/ {print $3; exit}')"
        if [ -n "$GW" ]; then
            # Restore the metric netifd uses for the WAN (10 on this GL.iNet setup).
            WAN_METRIC="$(uci -q get "network.${WAN_UCI_IFACE:-wan}.metric" 2>/dev/null || echo 10)"
            ip route replace default via "$GW" dev "$WAN_IF" metric "$WAN_METRIC"
            ip -4 route del default dev "$WAN_IF" metric 1 2>/dev/null || true
        fi
        if ip link show dev "$TUN_IF" >/dev/null 2>&1 && pidof usque-rs >/dev/null 2>&1; then
            ip route del default dev "$TUN_IF" 2>/dev/null || true
            ip route add default dev "$TUN_IF" metric 5 2>/dev/null || \
                ip route replace default dev "$TUN_IF" metric 5
            ip -6 route del default dev "$TUN_IF" 2>/dev/null || true
            ip -6 route add default dev "$TUN_IF" metric 5 2>/dev/null || \
                ip -6 route replace default dev "$TUN_IF" metric 5
            log "game_mode OFF: WARP default restored (metric 5, IPv6 active, filter_aaaa=0)."
        else
            log "game_mode OFF: marker cleared; tunnel not running — start via ensure_network/tunnel.sh."
            sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        fi
        "$0" status
        ;;
    *)
        usage
        ;;
esac

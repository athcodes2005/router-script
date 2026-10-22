#!/bin/sh
# Destination policy for Google services; independent of the WARP lifecycle.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
[ ! -f "$DIR/.env" ] || . "$DIR/.env"
. "$DIR/defaults.sh"
GOOGLE_TABLE=102
GOOGLE_PRIORITY=710
GOOGLE_MARK=0x100000
GOOGLE_MASK=0x100000
STATE_DIR="${GOOGLE_STATE_DIR:-/tmp/router-script-google}"
mkdir -p "$STATE_DIR"

# DNS configuration mode is called before dnsmasq restarts. It preserves other
# domain sets and creates sets before DNS can populate them.
for family in 4 6; do
    FAMILY=inet
    [ "$family" -eq 4 ] || FAMILY=inet6
    ipset create "google_net$family" hash:net family "$FAMILY" maxelem 65536 -exist
    ipset create "google_dns$family" hash:ip family "$FAMILY" timeout 86400 maxelem 65536 -exist
done
if [ "${1:-}" = configure-dns ]; then
    for ENTRY in $(uci -q get dhcp.@dnsmasq[0].ipset 2>/dev/null || true); do
        case "$ENTRY" in */google_dns4,google_dns6) uci del_list "dhcp.@dnsmasq[0].ipset=$ENTRY";; esac
    done
    while IFS= read -r DOMAIN; do
        case "$DOMAIN" in ''|\#*) continue;; esac
        uci add_list "dhcp.@dnsmasq[0].ipset=/$DOMAIN/google_dns4,google_dns6"
    done < "$DIR/google_domains.txt"
    exit 0
fi
if [ "${1:-}" = check-dns ]; then
    # One awk pass: a tr|grep pair per domain cost ~160 processes every tick.
    CURRENT=" $(uci -q get dhcp.@dnsmasq[0].ipset 2>/dev/null | tr '\n' ' ' || true) "
    awk -v current="$CURRENT" '
        $0 == "" || /^#/ { next }
        index(current, " /" $0 "/google_dns4,google_dns6 ") == 0 { missing = 1 }
        END { exit missing }
    ' "$DIR/google_domains.txt"
    exit 0
fi

GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
[ -n "$GW" ] || { echo 'Google WAN policy: WAN gateway missing' >&2; exit 1; }
HASH="$(sha256sum "$DIR/google_service_ranges.txt" | cut -d ' ' -f 1)"
# If the firewall or a reboot removed the sets, reload even with a saved hash.
if [ "$(cat "$STATE_DIR/ranges.sha" 2>/dev/null || true)" != "$HASH" ] ||
    ! ipset test google_net4 8.8.8.8 >/dev/null 2>&1 ||
    ! ipset test google_net6 2001:4860:4860::8888 >/dev/null 2>&1; then
    for family in 4 6; do
        FAMILY=inet
        [ "$family" -eq 4 ] || FAMILY=inet6
        ipset create "google_stage$family" hash:net family "$FAMILY" maxelem 65536 -exist
        ipset flush "google_stage$family"
    done
    while IFS= read -r PREFIX; do
        case "$PREFIX" in
            ''|\#*) continue;;
            *:*) ipset add google_stage6 "$PREFIX";;
            *) ipset add google_stage4 "$PREFIX";;
        esac
    done < "$DIR/google_service_ranges.txt"
    ipset swap google_stage4 google_net4
    ipset swap google_stage6 google_net6
    ipset destroy google_stage4
    ipset destroy google_stage6
    printf '%s\n' "$HASH" > "$STATE_DIR/ranges.sha"
fi

ip route replace "$LAN_SUBNET" dev "$LAN_IF" table "$GOOGLE_TABLE"
WAN_NET="$(ip -4 route show dev "$WAN_IF" scope link | awk '$1 ~ /\// {print $1; exit}')"
[ -z "$WAN_NET" ] || ip route replace "$WAN_NET" dev "$WAN_IF" table "$GOOGLE_TABLE"
ip route replace default via "$GW" dev "$WAN_IF" table "$GOOGLE_TABLE"
# Explicitly tunnel-bound router health probes must continue testing WARP.
if ! ip rule show | grep -Eq "^690:.*oif $TUN_IF .*lookup main"; then
    ip rule add priority 690 oif "$TUN_IF" lookup main
fi
if ! ip rule show | grep -Eq "^$GOOGLE_PRIORITY:.*fwmark $GOOGLE_MARK/$GOOGLE_MASK .*lookup $GOOGLE_TABLE"; then
    ip rule add priority "$GOOGLE_PRIORITY" fwmark "$GOOGLE_MARK/$GOOGLE_MASK" table "$GOOGLE_TABLE"
fi

# Each rule is installed only if absent. Never flush active chains every 30s.
for SET in google_net4 google_dns4; do
    iptables -t mangle -C PREROUTING -i "$LAN_IF" -m set --match-set "$SET" dst -j MARK --set-xmark "$GOOGLE_MARK/$GOOGLE_MASK" 2>/dev/null ||
        iptables -t mangle -I PREROUTING 1 -i "$LAN_IF" -m set --match-set "$SET" dst -j MARK --set-xmark "$GOOGLE_MARK/$GOOGLE_MASK"
    iptables -t mangle -C OUTPUT -m set --match-set "$SET" dst -j MARK --set-xmark "$GOOGLE_MARK/$GOOGLE_MASK" 2>/dev/null ||
        iptables -t mangle -I OUTPUT 1 -m set --match-set "$SET" dst -j MARK --set-xmark "$GOOGLE_MARK/$GOOGLE_MASK"
done
# No native WAN IPv6: hard rejection avoids TCP soft-error retry delays.
for SET in google_net6 google_dns6; do
    for CHAIN in FORWARD OUTPUT; do
        # OUTPUT protects router clients too; FORWARD is scoped to the LAN.
        set --
        [ "$CHAIN" != FORWARD ] || set -- -i "$LAN_IF"
        ip6tables -C "$CHAIN" "$@" -m set --match-set "$SET" dst -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null ||
            ip6tables -I "$CHAIN" 1 "$@" -m set --match-set "$SET" dst -j REJECT --reject-with icmp6-port-unreachable
        ip6tables -C "$CHAIN" "$@" -p tcp -m set --match-set "$SET" dst -j REJECT --reject-with tcp-reset 2>/dev/null ||
            ip6tables -I "$CHAIN" 1 "$@" -p tcp -m set --match-set "$SET" dst -j REJECT --reject-with tcp-reset
        # Remove the initial soft-error variant during an in-place upgrade.
        ip6tables -D "$CHAIN" "$@" -m set --match-set "$SET" dst -j REJECT --reject-with icmp6-no-route 2>/dev/null || true
    done
done

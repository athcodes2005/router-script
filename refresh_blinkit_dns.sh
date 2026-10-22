#!/bin/sh
# Refresh exact Blinkit names as IPv4-only local DNS records. Routes are
# installed before publishing addresses so clients never race the next cron run,
# and a replaced address loses its route only after it is unpublished.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
[ ! -f "$DIR/.env" ] || . "$DIR/.env"
. "$DIR/defaults.sh"
BLINKIT_DNS_SERVERS="${BLINKIT_DNS_SERVERS:-8.8.8.8 8.8.4.4}"
DNSMASQ_PID_DIR="${DNSMASQ_PID_DIR:-/var/run}"
mkdir -p "$BLINKIT_HOSTS_DIR"
# Stage outside addn-hosts directory: dnsmasq reads every file inside it.
WORK="$(mktemp -d /tmp/router-blinkit-dns.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
HOSTS="$BLINKIT_HOSTS_DIR/hosts"
: > "$WORK/hosts"
GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
[ -n "$GW" ] || { echo 'Blinkit DNS: no WAN gateway; preserving records.' >&2; exit 1; }
# Resolve every name before changing routes: a run that stops early must not
# leave routes for answers it never publishes.
for DOMAIN in $BLINKIT_IPV4_DOMAINS; do
    ADDRESSES=""
    for SERVER in $BLINKIT_DNS_SERVERS; do
        # Query upstream directly, never our own locally pinned answers.
        ADDRESSES="$(timeout 3 nslookup "$DOMAIN" "$SERVER" 2>/dev/null |
            awk '/^Address [0-9]+: / && $3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $3}')"
        [ -z "$ADDRESSES" ] || break
    done
    if [ -z "$ADDRESSES" ] && [ -f "$HOSTS" ]; then
        ADDRESSES="$(awk -v domain="$DOMAIN" '$2 == domain {print $1}' "$HOSTS")"
    fi
    [ -n "$ADDRESSES" ] || { echo "Blinkit DNS: no current or saved IPv4 for $DOMAIN." >&2; exit 1; }
    for ADDRESS in $ADDRESSES; do
        printf '%s %s\n' "$ADDRESS" "$DOMAIN" >> "$WORK/hosts"
    done
done
sort -u "$WORK/hosts" > "$WORK/sorted"
while read -r ADDRESS _; do
    ip route replace "$ADDRESS/32" via "$GW" dev "$WAN_IF" metric 1
done < "$WORK/sorted"
if ! cmp -s "$WORK/sorted" "$HOSTS"; then
    # Addresses the new set drops, taken before the old set is replaced.
    : > "$WORK/stale"
    if [ -f "$HOSTS" ]; then
        awk 'FILENAME == ARGV[1] { keep[$1]; next } !($1 in keep) { print $1 }' "$WORK/sorted" "$HOSTS" |
            sort -u > "$WORK/stale"
    fi
    # Atomic replacement on the destination filesystem. Hidden staging stays
    # outside the directory exposed to dnsmasq and its optional jail.
    STAGE="$(mktemp "${BLINKIT_HOSTS_DIR}.XXXXXX")"
    trap 'rm -rf "$WORK"; rm -f "$STAGE"' EXIT
    cat "$WORK/sorted" > "$STAGE"
    chmod 644 "$STAGE"
    mv "$STAGE" "$HOSTS"
    # HUP reads hosts files without restarting DNS/DHCP or Wi-Fi.
    RELOADED=0
    for PID_FILE in "$DNSMASQ_PID_DIR"/dnsmasq*.pid; do
        [ -f "$PID_FILE" ] || continue
        PID="$(cat "$PID_FILE")"
        case "$PID" in ''|*[!0-9]*) continue;; esac
        if kill -HUP "$PID" 2>/dev/null; then RELOADED=$((RELOADED + 1)); fi
    done
    # The HUP also clears dnsmasq's whole cache, so log each change to show the rate.
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Blinkit DNS: records changed ($(grep -c '' "$HOSTS") entries); dnsmasq PIDs reloaded: $RELOADED (a reload clears the cache)."
    # No other refresher runs while WARP is down or game mode is on, so the
    # dropped addresses' routes are ours to remove. One that another refresher
    # still lists is left to it: the public refresher removes it on the next
    # healthy tick.
    if [ -s "$WORK/stale" ]; then
        cat "$CAMPUS_ROUTES_FILE" "$DIRECT_PUBLIC_ROUTES_FILE" "$GAME_SESSION_ROUTES_FILE" > "$WORK/listed" 2>/dev/null || true
        REMOVED=0
        LEFT=0
        while read -r ADDRESS; do
            if grep -Fqx "$ADDRESS/32" "$WORK/listed"; then
                LEFT=$((LEFT + 1))
            elif ip route del "$ADDRESS/32" via "$GW" dev "$WAN_IF" metric 1 2>/dev/null; then
                REMOVED=$((REMOVED + 1))
            fi
        done < "$WORK/stale"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Blinkit DNS: replaced-address routes removed: $REMOVED, left to another refresher: $LEFT."
    fi
fi

#!/bin/sh
# Refresh exact Blinkit names as IPv4-only local DNS records. Routes are
# installed before publishing addresses so clients never race the next cron run.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
[ ! -f "$DIR/.env" ] || . "$DIR/.env"
WAN_IF="${WAN_IF:-eth0}"
BLINKIT_IPV4_DOMAINS="${BLINKIT_IPV4_DOMAINS:-api3.blinkit.com jumbo.blinkit.com}"
BLINKIT_HOSTS_DIR="${BLINKIT_HOSTS_DIR:-/etc/router-script/blinkit-hosts}"
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
        ip route replace "$ADDRESS/32" via "$GW" dev "$WAN_IF" metric 1
        printf '%s %s\n' "$ADDRESS" "$DOMAIN" >> "$WORK/hosts"
    done
done
sort -u "$WORK/hosts" > "$WORK/sorted"
if ! cmp -s "$WORK/sorted" "$HOSTS"; then
    # Atomic replacement on the destination filesystem. Hidden staging stays
    # outside the directory exposed to dnsmasq and its optional jail.
    STAGE="$(mktemp "${BLINKIT_HOSTS_DIR}.XXXXXX")"
    trap 'rm -rf "$WORK"; rm -f "$STAGE"' EXIT
    cat "$WORK/sorted" > "$STAGE"
    chmod 644 "$STAGE"
    mv "$STAGE" "$HOSTS"
    # HUP reads hosts files without restarting DNS/DHCP or Wi-Fi.
    for PID_FILE in "$DNSMASQ_PID_DIR"/dnsmasq*.pid; do
        [ -f "$PID_FILE" ] || continue
        PID="$(cat "$PID_FILE")"
        case "$PID" in ''|*[!0-9]*) continue;; esac
        kill -HUP "$PID" 2>/dev/null || true
    done
fi

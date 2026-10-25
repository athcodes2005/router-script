#!/bin/sh

# Configure DNS with plain resolvers first, DoH as last resort:
#   1. 8.8.8.8 (Google primary)
#   2. 8.8.4.4 (Google secondary)
#   3. 10.200.1.11 (campus resolver)
#   4. 127.0.0.1#5453 (dnscrypt-proxy DoH — fallback only)
#
# Campus-specific domains go directly to 10.200.1.11 via dnsmasq server= directives.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file dns)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

DNSCRYPT_TOML="${DNSCRYPT_TOML:-/etc/dnscrypt-proxy2/dnscrypt-proxy.toml}"
PORTAL_IP="${PORTAL_IP:-10.201.250.201}"
SSO_IP="${SSO_IP:-10.200.1.100}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_DOMAINS="${CAMPUS_DOMAINS:-internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
LAN_IF="${LAN_IF:-br-lan}"

# DNS servers in priority order
DNS_SERVERS="8.8.8.8 8.8.4.4 $CAMPUS_DNS_IP 127.0.0.1#5453"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# --- dnscrypt-proxy: keep running as last-resort upstream on 127.0.0.1#5453 ---

# Set a TOML key to a literal value, inserting it at the end if the key is missing.
set_toml_key() {
    _toml="$1"; _key="$2"; _value="$3"
    if [ -f "$_toml" ] && grep -q "^$_key[[:space:]]*=" "$_toml"; then
        sed -i "s|^$_key[[:space:]]*=.*|$_key = $_value|" "$_toml"
    else
        printf '\n%s = %s\n' "$_key" "$_value" >> "$_toml"
    fi
}

# Ensure the dnscrypt-proxy config (and its directory) exists before editing.
[ -d "$(dirname "$DNSCRYPT_TOML")" ] || mkdir -p "$(dirname "$DNSCRYPT_TOML")"
[ -f "$DNSCRYPT_TOML" ] || : > "$DNSCRYPT_TOML"

# If a truncated config lost its resolver list, restore the known-good backup so
# dnscrypt-proxy has server_names (otherwise it exits with "No servers
# configured"). The statements below re-apply the listen/block_ipv6 overrides.
if ! grep -q "^server_names[[:space:]]*=" "$DNSCRYPT_TOML" \
    && [ -f "$DNSCRYPT_TOML" ]; then
    if [ -f "$DNSCRYPT_TOML.bak" ]; then
        cp "$DNSCRYPT_TOML.bak" "$DNSCRYPT_TOML"
        log "dnscrypt-proxy config lacked server_names; restored from backup."
    else
        set_toml_key "$DNSCRYPT_TOML" server_names "['quad9-doh-ip4-port443-nofilter-ecs-pri','quad9-doh-ip6-port443-nofilter-ecs-pri']"
    fi
fi

# dnscrypt-proxy MUST answer on 127.0.0.1:5453 (dnsmasq's last-resort upstream).
# Without an explicit listen_addresses it defaults to 127.0.0.1:53 and collides
# with dnsmasq, crashing in a bind()-use loop.
set_toml_key "$DNSCRYPT_TOML" listen_addresses "['127.0.0.1:5453']"
set_toml_key "$DNSCRYPT_TOML" block_ipv6 false

if [ -x /etc/init.d/dnscrypt-proxy ]; then
    log "Restarting dnscrypt-proxy (DoH fallback)"
    /etc/init.d/dnscrypt-proxy restart
fi

# --- dnsmasq: configure multi-server with strict-order ---

# Clear existing server entries
uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true

# Add servers in priority order (strict-order means try in this order)
for SERVER in $DNS_SERVERS; do
    uci add_list dhcp.@dnsmasq[0].server="$SERVER"
done

# strict-order: query servers in the order listed, not all at once
uci set dhcp.@dnsmasq[0].strictorder='1'

# Keep the configured order deterministic. WAN-provided resolv.conf entries
# would otherwise be appended silently and could bypass this resolver chain.
uci set dhcp.@dnsmasq[0].noresolv='1'

# Campus-specific domain forwarding via dnsmasq server=/domain/ip directives
# First remove any existing campus domain server entries
for DOMAIN in $CAMPUS_DOMAINS; do
    uci del_list dhcp.@dnsmasq[0].server="/$DOMAIN/$CAMPUS_DNS_IP" 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].server="/$DOMAIN/$CAMPUS_DNS_IP"
done

# Pinned portal/SSO IPs as local address records.  When campus DNS is down,
# dnsmasq answers from these instead of forwarding to the dead resolver, so
# login.sh can always reach the captive-portal OAuth chain.
# Verified 2026-08-19; update here if IITB changes internal addresses.
for ENTRY in $(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true); do
    case "$ENTRY" in
        /internet.iitb.ac.in/*|/sso.iitb.ac.in/*)
            uci del_list "dhcp.@dnsmasq[0].address=$ENTRY" ;;
    esac
done
uci add_list dhcp.@dnsmasq[0].address="/internet.iitb.ac.in/$PORTAL_IP"
uci add_list dhcp.@dnsmasq[0].address="/sso.iitb.ac.in/$SSO_IP"

uci commit dhcp

log "Restarting dnsmasq"
/etc/init.d/dnsmasq restart
sleep 3

# --- Verification ---
log "DNS configuration applied:"
log "  Upstream servers (strict-order): $DNS_SERVERS"
log "  Campus domains -> $CAMPUS_DNS_IP:"
for DOMAIN in $CAMPUS_DOMAINS; do
    log "    $DOMAIN"
done
log "  dnscrypt-proxy (DoH): 127.0.0.1:5453 (last resort)"
log "  block_ipv6 = false"
log "  Portal/SSO pinned IPs (campus-DNS fallback):"
log "    internet.iitb.ac.in -> $PORTAL_IP"
log "    sso.iitb.ac.in -> $SSO_IP"

log "Verification:"
timeout 3 nslookup google.com 127.0.0.1 | sed -n '1,6p' || true
echo "---"
timeout 3 nslookup -query=AAAA google.com 127.0.0.1 | sed -n '1,8p' || true
echo "---"
for DOMAIN in $CAMPUS_DOMAINS; do
    timeout 3 nslookup "$DOMAIN" 127.0.0.1 | sed -n '1,8p' || true
done

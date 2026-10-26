#!/bin/sh

# Configure DNS with encrypted DNS (DoT/DoH on 127.0.0.1#5453) first, plain
# resolvers as fallback:
#   1. 127.0.0.1#5453 (dnsproxy DoT/DoH primary — Cloudflare 1.1.1.1 + Quad9 9.9.9.9)
#   2. 8.8.8.8 (Google fallback)
#   3. 8.8.4.4 (Google secondary fallback)
#   4. 10.200.1.11 (campus resolver fallback)
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
. "$DIR/defaults.sh"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# --- Encrypted DNS daemon on 127.0.0.1#5453 (dnsproxy; dnscrypt-proxy2 was replaced by dnsproxy in 4.11.0) ---

# Replaced by dnsproxy on firmware 4.11.0+:
# set_toml_key() {
#     _toml="$1"; _key="$2"; _value="$3"
#     if [ -f "$_toml" ] && grep -q "^$_key[[:space:]]*=" "$_toml"; then
#         sed -i "s|^$_key[[:space:]]*=.*|$_key = $_value|" "$_toml"
#     else
#         printf '\n%s = %s\n' "$_key" "$_value" >> "$_toml"
#     fi
# }
# [ -d "$(dirname "$DNSCRYPT_TOML")" ] || mkdir -p "$(dirname "$DNSCRYPT_TOML")"
# [ -f "$DNSCRYPT_TOML" ] || : > "$DNSCRYPT_TOML"
# if ! grep -q "^server_names[[:space:]]*=" "$DNSCRYPT_TOML" && [ -f "$DNSCRYPT_TOML" ]; then
#     if [ -f "$DNSCRYPT_TOML.bak" ]; then
#         cp "$DNSCRYPT_TOML.bak" "$DNSCRYPT_TOML"
#         log "dnscrypt-proxy config lacked server_names; restored from backup."
#     else
#         set_toml_key "$DNSCRYPT_TOML" server_names "['quad9-doh-ip4-port443-nofilter-ecs-pri','quad9-doh-ip6-port443-nofilter-ecs-pri']"
#     fi
# fi
# set_toml_key "$DNSCRYPT_TOML" listen_addresses "['127.0.0.1:5453']"
# set_toml_key "$DNSCRYPT_TOML" block_ipv6 false
# if [ -x /etc/init.d/dnscrypt-proxy ]; then
#     log "Restarting dnscrypt-proxy (DoH fallback)"
#     /etc/init.d/dnscrypt-proxy restart
# fi

[ -d "$(dirname "$DNSPROXY_YAML")" ] || mkdir -p "$(dirname "$DNSPROXY_YAML")"
cat > "$DNSPROXY_YAML" <<'EOF'
---
upstream:
  - "tls://1.1.1.1:853"
  - "tls://1.0.0.1:853"
  - "https://cloudflare-dns.com/dns-query"
  - "tls://9.9.9.9:853"
  - "https://dns.quad9.net/dns-query"
bootstrap:
  - "8.8.8.8:53"
  - "8.8.4.4:53"
  - "1.1.1.1:53"
listen-addrs:
  - "127.0.0.1"
  - "::1"
listen-ports:
  - 5453
timeout: '5s'
EOF
chmod 600 "$DNSPROXY_YAML"
uci set gl-dns-v2.@dns[0].mode='secure' 2>/dev/null || true
uci set gl-dns-v2.@dns[0].proto='doh' 2>/dev/null || true
uci commit gl-dns-v2 2>/dev/null || true
if [ -x /etc/init.d/dnsproxy ]; then
    log "Restarting dnsproxy (encrypted DoT/DoH primary on 127.0.0.1:5453)"
    /etc/init.d/dnsproxy restart
fi

# --- dnsmasq: configure multi-server with strict-order ---

# Clear existing server entries
uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true

# Add servers in priority order (strict-order means try in this order)
for SERVER in $DNS_SERVERS; do
    uci add_list dhcp.@dnsmasq[0].server="$SERVER"
done

# Exact local zones plus refreshed IPv4 hosts return NOERROR/NODATA for AAAA
# (dnsmasq 2.85 on older firmware, 2.92 on 4.11.0) without disabling IPv6 for
# unrelated services.
sh "$DIR/refresh_blinkit_dns.sh" || log "Blinkit refresh deferred; retaining saved DNS records."
for DOMAIN in $BLINKIT_IPV4_DOMAINS; do
    uci add_list dhcp.@dnsmasq[0].server="/$DOMAIN/"
done
uci del_list dhcp.@dnsmasq[0].addnhosts="$BLINKIT_HOSTS_DIR" 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].addnhosts="$BLINKIT_HOSTS_DIR"

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

sh "$DIR/google_wan_policy.sh" configure-dns
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
log "  dnsproxy (DoT/DoH): 127.0.0.1:5453 (primary)"
# Replaced by dnsproxy on firmware 4.11.0+:
# log "  dnscrypt-proxy (DoH): 127.0.0.1:5453 (last resort)"
# log "  block_ipv6 = false"
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

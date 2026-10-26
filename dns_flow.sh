#!/bin/sh

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi
. "$DIR/defaults.sh"

echo "=== LISTENERS (53/5453) ==="
netstat -lntup 2>/dev/null | grep -E '(:53 |:53$|:5453 |:5453$)' || true

echo ""
echo "=== DNSMASQ SERVERS ==="
uci show dhcp.@dnsmasq[0] 2>/dev/null | grep -E 'server|strictorder|noresolv|address' || true

echo ""
echo "=== PORTAL/SSO PINS (expected address=) ==="
echo "internet.iitb.ac.in -> $PORTAL_IP"
echo "sso.iitb.ac.in -> $SSO_IP"

echo ""
echo "=== DNSPROXY SUMMARY (replaced dnscrypt-proxy2 on firmware 4.11.0+) ==="
# Replaced by dnsproxy:
# grep -n 'server_names\|listen_addresses\|block_ipv6' /etc/dnscrypt-proxy2/dnscrypt-proxy.toml 2>/dev/null || echo "dnscrypt-proxy.toml not found"
cat "$DNSPROXY_YAML" 2>/dev/null || echo "dnsproxy.yaml not found"

echo ""
echo "=== ROUTE TO DNS SERVERS ==="
ip route get 8.8.8.8 2>/dev/null || true
ip route get 8.8.4.4 2>/dev/null || true
ip route get "$CAMPUS_DNS_IP" 2>/dev/null || true

echo ""
echo "=== LIVE TESTS: dnsmasq (127.0.0.1) ==="
timeout 3 nslookup google.com 127.0.0.1 || true
echo "---"
timeout 3 nslookup -query=AAAA google.com 127.0.0.1 || true
echo "---"
for DOMAIN in $CAMPUS_DOMAINS; do
    timeout 3 nslookup "$DOMAIN" 127.0.0.1 || true
done

echo ""
echo "=== LIVE TESTS: direct (8.8.8.8) ==="
timeout 3 nslookup google.com 8.8.8.8 || true

echo ""
echo "=== LIVE TESTS: LAN entrypoint (192.168.8.1) ==="
timeout 3 nslookup google.com 192.168.8.1 || true
echo "---"
for DOMAIN in $CAMPUS_DOMAINS; do
    timeout 3 nslookup "$DOMAIN" 192.168.8.1 || true
done

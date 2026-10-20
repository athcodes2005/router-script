#!/bin/sh

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-80}"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

. "$DIR/paths.sh"

WAN_IF="${WAN_IF:-eth0}"
WAN_UCI_IFACE="${WAN_UCI_IFACE:-wan}"
LAN_IF="${LAN_IF:-br-lan}"
TUN_IF="${TUN_IF:-tun0}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_DOMAINS="${CAMPUS_DOMAINS:-internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
CAMPUS_DIRECT_DOMAINS="${CAMPUS_DIRECT_DOMAINS:-www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
WIFI_2G_DEVICE="${WIFI_2G_DEVICE:-mt798111}"
WIFI_5G_DEVICE="${WIFI_5G_DEVICE:-mt798112}"
DNSCRYPT_TOML="${DNSCRYPT_TOML:-/etc/dnscrypt-proxy2/dnscrypt-proxy.toml}"
WARP_CLIENTS_FILE="$DIR/warp_clients.txt"
WARP_CLIENT_TABLE="${WARP_CLIENT_TABLE:-100}"
WARP_READY_FILE="${WARP_READY_FILE:-/tmp/router-script-warp-ready}"
CAMPUS_ROUTES_FILE="${CAMPUS_ROUTES_FILE:-/tmp/router-script-campus-host-routes}"

section() {
    printf '\n=== %s ===\n' "$1"
}

run() {
    "$@" 2>&1 || true
}

# netifd's wireless status embeds each interface's configuration, WPA
# passphrases included. Snapshots leave the router, so never record secrets.
redact_secrets() {
    sed -E 's/("[^"]*(key|pass|secret|psk)[^"]*"[[:space:]]*:[[:space:]]*")(\\.|[^"\\])*"/\1<redacted>"/g'
}

show_log_tail() {
    section "RECENT $1"
    if [ -f "$2" ]; then
        tail -n "$LOG_TAIL_LINES" "$2"
    else
        printf 'Not found: %s\n' "$2"
    fi
}

echo "========================================"
echo "          DIAGNOSTICS START"
echo "========================================"
date

section "ACTIVE CONFIG"
printf 'WAN_IF=%s  LAN_IF=%s  TUN_IF=%s\n' "$WAN_IF" "$LAN_IF" "$TUN_IF"
printf 'CAMPUS_DNS=%s  CAMPUS_DOMAINS=%s\n' "$CAMPUS_DNS_IP" "$CAMPUS_DOMAINS"
printf 'CAMPUS_DIRECT_DOMAINS=%s\n' "$CAMPUS_DIRECT_DOMAINS"

section "UPTIME & SYSTEM"
run uname -a
run uptime
run free
run df -h
run sh -c "du -k /tmp/* 2>/dev/null | sort -n | tail -n 20"

section "CRON"
run crontab -l

section "KEY PROCESSES"
run sh -c "ps w | grep -E 'dnscrypt-proxy|dnsmasq|odhcpd|usque-rs|tcpdump' | grep -v grep"

section "INTERFACES"
run ip addr show

section "WI-FI STABILITY CONFIG"
for DEVICE in "$WIFI_2G_DEVICE" "$WIFI_5G_DEVICE"; do
    printf '%s country=%s htmode=%s channel=%s\n' \
        "$DEVICE" \
        "$(uci -q get "wireless.$DEVICE.country" 2>/dev/null || echo unknown)" \
        "$(uci -q get "wireless.$DEVICE.htmode" 2>/dev/null || echo unknown)" \
        "$(uci -q get "wireless.$DEVICE.channel" 2>/dev/null || echo unknown)"
done
ubus call network.wireless status 2>&1 | redact_secrets
run sh -c "dmesg | grep -Ei 'tx_free|deauth|disassoc|wifi_sys_disconn|radar' | tail -n 80"

section "QUEUE AND LINK COUNTERS"
run tc -s qdisc show
run ip -s link show dev "$WAN_IF"
run ip -s link show dev "$TUN_IF"

section "WAN IFSTATUS"
printf 'carrier=%s\n' "$(cat "/sys/class/net/$WAN_IF/carrier" 2>/dev/null || echo unknown)"
run ifstatus "$WAN_UCI_IFACE"

section "IPV4 ROUTES"
run ip -4 route show

section "IPV6 ROUTES"
run ip -6 route show

section "POLICY RULES & LEGACY WARP CLIENT ROUTES"
run ip rule show
run ip route show table "$WARP_CLIENT_TABLE"
if [ -f "$WARP_CLIENTS_FILE" ]; then
    run cat "$WARP_CLIENTS_FILE"
else
    echo "No warp_clients.txt"
fi

section "ROUTE LOOKUPS"
run ip route get "$CAMPUS_DNS_IP"
run ip route get 1.1.1.1
run ip route get 8.8.8.8
run ip -6 route get 2606:4700:4700::1111
if [ -f "$CAMPUS_ROUTES_FILE" ]; then
    printf 'Dynamic campus host routes:\n'
    while IFS= read -r ROUTE; do
        [ -n "$ROUTE" ] && run ip route get "${ROUTE%/32}"
    done < "$CAMPUS_ROUTES_FILE"
else
    echo "No dynamic campus host-route state"
fi

section "DNS LISTENERS (53/5453)"
run sh -c "netstat -lntup 2>/dev/null | grep -E '(:53 |:53$|:5453 |:5453$)'"

section "DNSMASQ UCI"
run uci show dhcp

section "DNSCRYPT SUMMARY"
run sh -c "grep -n 'server_names\|listen_addresses\|forwarding_rules\|block_ipv6' '$DNSCRYPT_TOML'"

section "LEGACY BLOCKED SITES (unused by full tunnel)"
if [ -f "$DIR/blocked_sites.txt" ]; then
    run cat "$DIR/blocked_sites.txt"
else
    echo "No blocked_sites.txt"
fi

section "DNS TESTS (127.0.0.1)"
run timeout 3 nslookup google.com 127.0.0.1
run timeout 3 nslookup -query=AAAA google.com 127.0.0.1
for DOMAIN in $CAMPUS_DOMAINS; do
    run timeout 3 nslookup "$DOMAIN" 127.0.0.1
done

section "DNS TESTS (direct resolvers)"
run timeout 3 nslookup google.com 8.8.8.8
run timeout 3 nslookup internet.iitb.ac.in "$CAMPUS_DNS_IP"

section "PING TESTS"
run ping -4 -W 3 -c 3 "$CAMPUS_DNS_IP"
run ping -4 -W 3 -c 3 8.8.8.8
run ping -6 -W 3 -c 3 2606:4700:4700::1111

section "HTTP/HTTPS TESTS"
run curl -4 -sS --interface "$WAN_IF" --connect-timeout 5 --max-time 15 -o /dev/null -w 'direct_ipv4_status=%{http_code}\n' https://www.google.com/generate_204
run curl -4 -sS --interface "$TUN_IF" --connect-timeout 5 --max-time 15 -o /dev/null -w 'warp_ipv4_status=%{http_code}\n' https://www.google.com/generate_204
run curl -6 -sS --interface "$TUN_IF" --connect-timeout 5 --max-time 15 -o /dev/null -w 'warp_ipv6_status=%{http_code}\n' https://www.google.com/generate_204

section "TUNNEL INTERFACE"
run ip addr show dev "$TUN_IF"

section "TUNNEL PROCESS"
run sh -c "pidof usque-rs; ps w | grep usque-rs | grep -v grep"
if [ -s "$WARP_READY_FILE" ]; then
    printf 'CONNECT-IP ready marker present (PID %s)\n' "$(cat "$WARP_READY_FILE" 2>/dev/null || echo unknown)"
else
    echo "CONNECT-IP ready marker missing"
fi

section "FIREWALL: NAT"
run iptables -t nat -L POSTROUTING -v -n
run ip6tables -t nat -L POSTROUTING -v -n

section "FIREWALL: FORWARD"
run iptables -L FORWARD -v -n
run ip6tables -L FORWARD -v -n

show_log_tail "LOGIN LOG" "$(prepare_log_file login)"
show_log_tail "TUNNEL LOG" "$(prepare_log_file tunnel)"
show_log_tail "DNS LOG" "$(prepare_log_file dns)"
show_log_tail "ENSURE LOG" "$(prepare_log_file ensure)"
show_log_tail "WI-FI LOG" "$(prepare_log_file wifi)"

section "RECENT SYSTEM LOGS"
run sh -c "logread | grep -E 'wan|udhcpc|eth0|dnsmasq|dnscrypt|odhcpd|usque|tun0|wireless|wifi' | tail -n 100"

echo ""
echo "========================================"
echo "          DIAGNOSTICS END"
echo "========================================"

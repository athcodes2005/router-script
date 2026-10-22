#!/bin/sh

# Start usque-rs WARP as the default IPv4 and IPv6 gateway:
#   - Public IPv4 and IPv6 traffic routes through tun0
#   - Campus-private IPv4 and the WARP transport endpoints stay on eth0

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$DIR/usque-rs"
CONFIG_FILE="$DIR/config.json"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file tunnel)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

WAN_IF="${WAN_IF:-eth0}"
LAN_IF="${LAN_IF:-br-lan}"
LAN_SUBNET="${LAN_SUBNET:-192.168.8.0/24}"
TUN_IF="${TUN_IF:-tun0}"
TUN_IPV4_MSS="${TUN_IPV4_MSS:-1240}"
TUN_IPV6_MSS="${TUN_IPV6_MSS:-1220}"
CAMPUS_NETS="${CAMPUS_NETS:-10.0.0.0/8 103.21.124.0/22}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_DIRECT_DOMAINS="${CAMPUS_DIRECT_DOMAINS:-www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
CAMPUS_ROUTES_FILE="${CAMPUS_ROUTES_FILE:-/tmp/router-script-campus-host-routes}"
# Selected public services that reject WARP/shared-proxy egress.  These are
# intentionally exact hostnames observed from the affected app; broad CDN
# ranges would accidentally bypass WARP for unrelated sites.
DIRECT_PUBLIC_DOMAINS="${DIRECT_PUBLIC_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com o1069899.ingest.us.sentry.io gemini.google.com game.clashroyaleapp.com id.supercell.com init.mkt.supercell.com o315582.ingest.sentry.io clashroyale.com www.clashroyale.com}"
DIRECT_PUBLIC_ROUTES_FILE="${DIRECT_PUBLIC_ROUTES_FILE:-/tmp/router-script-direct-public-host-routes}"
GAME_SESSION_PORTS="${GAME_SESSION_PORTS:-9339}"
GAME_POLICY_TABLE="${GAME_POLICY_TABLE:-101}"
GAME_POLICY_PRIORITY="${GAME_POLICY_PRIORITY:-700}"
GAME_POLICY_MARK="${GAME_POLICY_MARK:-0x40000}"
GAME_POLICY_MASK="${GAME_POLICY_MASK:-0xf0000}"
WARP_ENDPOINTS="${WARP_ENDPOINTS:-162.159.198.1 162.159.192.1}"
WARP_CC="${WARP_CC:-cubic}"
WARP_READY_FILE="${WARP_READY_FILE:-/tmp/router-script-warp-ready}"
WARP_STARTUP_TIMEOUT="${WARP_STARTUP_TIMEOUT:-25}"

exec >> "$LOG_FILE" 2>&1

echo "========================================"

cleanup_on_exit() {
    STATUS=$?
    trap - EXIT INT TERM
    if [ "$STATUS" -ne 0 ]; then
        echo "[ERROR] Tunnel startup failed; reverting partial process and routing state."
        sh "$DIR/stop_tunnel.sh" >/dev/null 2>&1 || true
    fi
    exit "$STATUS"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Starting tunnel service at $(date)"
echo "========================================"

if [ ! -f "$EXECUTABLE" ]; then
    echo "[ERROR] $EXECUTABLE not found."
    exit 1
fi

chmod +x "$EXECUTABLE"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[INFO] Config not found. Registering usque-rs..."
    "$EXECUTABLE" --config "$CONFIG_FILE" register --accept-tos
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[ERROR] Failed to register usque-rs."
        exit 1
    fi
    echo "[SUCCESS] Registered usque-rs successfully."
fi

# Both files contain credentials/private keys and must never inherit scp's
# common world-readable default mode.
chmod 600 "$CONFIG_FILE" 2>/dev/null || true
[ -f "$ENV_FILE" ] && chmod 600 "$ENV_FILE" 2>/dev/null || true

# Always include the endpoint from the active registration. Cloudflare may
# rotate it, and a missing direct route would recursively send the WARP
# transport into its own tunnel.
CONFIG_ENDPOINT="$(jsonfilter -i "$CONFIG_FILE" -e '@.endpoint_v4' 2>/dev/null || true)"
case "$CONFIG_ENDPOINT" in
    *.*.*.*) WARP_ENDPOINTS="$WARP_ENDPOINTS $CONFIG_ENDPOINT" ;;
esac

echo "[INFO] Proceeding to start tunnel..."

NATIVETUN_HELP="$("$EXECUTABLE" nativetun --help 2>&1 || true)"
SUPPORTS_CC=0
SUPPORTS_READY=0
echo "$NATIVETUN_HELP" | grep -q 'congestion-control' && SUPPORTS_CC=1
echo "$NATIVETUN_HELP" | grep -q 'ready-file' && SUPPORTS_READY=1

# These settings are routing state, not process state; reapply them even when
# an existing usque-rs process is reused to repair drift.
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
sysctl -w net.ipv6.conf.all.forwarding=1

if pidof "$(basename "$EXECUTABLE")" >/dev/null 2>&1; then
    if ! ip link show dev "$TUN_IF" >/dev/null 2>&1; then
        echo "[ERROR] usque-rs is running but $TUN_IF does not exist."
        exit 1
    fi
    echo "[INFO] Reusing the running usque-rs process and repairing routing state."
else
    # usque-rs redraws a status line every second. Keep it off persistent flash;
    # liveness and active traffic checks are handled by ensure_network.sh.
    echo "[INFO] Starting usque-rs native TUN in the background..."
    rm -f "$WARP_READY_FILE"
    set -- "$EXECUTABLE" --config "$CONFIG_FILE" nativetun --interface-name "$TUN_IF"
    if [ "$SUPPORTS_CC" -eq 1 ]; then
        set -- "$@" --congestion-control "$WARP_CC"
    else
        echo "[WARNING] This usque-rs binary does not support congestion-control selection."
    fi
    if [ "$SUPPORTS_READY" -eq 1 ]; then
        set -- "$@" --ready-file "$WARP_READY_FILE"
    else
        echo "[WARNING] This usque-rs binary cannot signal CONNECT-IP readiness."
    fi
    "$@" >/dev/null 2>&1 &
    PID=$!
fi

# The TUN device is created before the QUIC and CONNECT-IP handshakes finish.
# Do not install public defaults until the client explicitly reports readiness.
PID="$(pidof "$(basename "$EXECUTABLE")" 2>/dev/null | awk '{print $1}')"
WAIT_COUNT=0
while [ -n "$PID" ] && kill -0 "$PID" >/dev/null 2>&1 && [ "$WAIT_COUNT" -lt "$WARP_STARTUP_TIMEOUT" ]; do
    if ip link show dev "$TUN_IF" >/dev/null 2>&1; then
        if [ "$SUPPORTS_READY" -eq 0 ] || [ -s "$WARP_READY_FILE" ]; then
            break
        fi
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null 2>&1 || ! ip link show dev "$TUN_IF" >/dev/null 2>&1; then
    echo "[ERROR] Failed to start usque-rs or create $TUN_IF."
    exit 1
fi
if [ "$SUPPORTS_READY" -eq 1 ] && [ ! -s "$WARP_READY_FILE" ]; then
    echo "[ERROR] CONNECT-IP did not become ready within ${WARP_STARTUP_TIMEOUT}s."
    exit 1
fi

echo "[SUCCESS] usque-rs CONNECT-IP is ready with PID $PID after ${WAIT_COUNT}s."

echo "[INFO] Configuring full-tunnel routing..."

DEFAULT_GW="$(ip route show default | grep -v "dev $TUN_IF" | head -n 1 | awk '/default/ {print $3}')"

if [ -z "$DEFAULT_GW" ]; then
    echo "[ERROR] No direct WAN gateway is available; refusing to install a recursive WARP default route."
    exit 1
fi

# Game session traffic uses dynamic Supercell endpoints.  A DNS-derived /32
# route is too late for the first packet (and cannot move an existing
# conntrack/NAT flow off WARP), so steer the small, well-known session port to
# the campus WAN before the normal full-tunnel policy runs.
ip route replace "$LAN_SUBNET" dev "$LAN_IF" table "$GAME_POLICY_TABLE"
ip route replace default via "$DEFAULT_GW" dev "$WAN_IF" table "$GAME_POLICY_TABLE"
while ip rule del priority "$GAME_POLICY_PRIORITY" fwmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" table "$GAME_POLICY_TABLE" 2>/dev/null; do :; done
ip rule add priority "$GAME_POLICY_PRIORITY" fwmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" table "$GAME_POLICY_TABLE"

if ! iptables -t mangle -N GAME_SESSION_POLICY 2>/dev/null; then
    iptables -t mangle -F GAME_SESSION_POLICY
fi
iptables -t mangle -F GAME_SESSION_POLICY
iptables -t mangle -A GAME_SESSION_POLICY -m connmark ! --mark 0x0/"$GAME_POLICY_MASK" -j CONNMARK --restore-mark --nfmask "$GAME_POLICY_MASK" --ctmask "$GAME_POLICY_MASK"
for PORT in $GAME_SESSION_PORTS; do
    iptables -t mangle -A GAME_SESSION_POLICY -i "$LAN_IF" -p tcp -m tcp --dport "$PORT" -m conntrack --ctstate NEW -j MARK --set-xmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK"
    iptables -t mangle -A GAME_SESSION_POLICY -i "$LAN_IF" -p tcp -m tcp --dport "$PORT" -m conntrack --ctstate NEW -j CONNMARK --save-mark --nfmask "$GAME_POLICY_MASK" --ctmask "$GAME_POLICY_MASK"
    iptables -t mangle -A GAME_SESSION_POLICY -i "$LAN_IF" -p udp -m udp --dport "$PORT" -m conntrack --ctstate NEW -j MARK --set-xmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK"
    iptables -t mangle -A GAME_SESSION_POLICY -i "$LAN_IF" -p udp -m udp --dport "$PORT" -m conntrack --ctstate NEW -j CONNMARK --save-mark --nfmask "$GAME_POLICY_MASK" --ctmask "$GAME_POLICY_MASK"
done
while iptables -t mangle -C PREROUTING -j GAME_SESSION_POLICY 2>/dev/null; do
    iptables -t mangle -D PREROUTING -j GAME_SESSION_POLICY
done
iptables -t mangle -I PREROUTING 1 -j GAME_SESSION_POLICY

# --- IPv4: public default through WARP, campus/private exceptions on WAN ---

# Ensure LAN stays on bridge
ip route replace "$LAN_SUBNET" dev "$LAN_IF" metric 1 2>/dev/null

if [ -n "$DEFAULT_GW" ]; then
    # Keep campus nets on WAN
    for NET in $CAMPUS_NETS; do
        ip route replace "$NET" via "$DEFAULT_GW" dev "$WAN_IF" metric 1
    done

    # Keep WARP endpoints on WAN
    for ENDPOINT in $WARP_ENDPOINTS; do
        ip route replace "$ENDPOINT" via "$DEFAULT_GW" dev "$WAN_IF" metric 1
    done

    # Some IITB-only pages use public addresses and decide access from the
    # source IP. Resolve those explicit hostnames with campus DNS and keep the
    # resulting IPv4 host routes off WARP. Remove the previous dynamic set
    # first so DNS changes do not leave stale exceptions behind.
    if [ -f "$CAMPUS_ROUTES_FILE" ]; then
        while IFS= read -r ROUTE; do
            [ -n "$ROUTE" ] && ip route del "$ROUTE" 2>/dev/null || true
        done < "$CAMPUS_ROUTES_FILE"
    fi
    : > "$CAMPUS_ROUTES_FILE"
    for DOMAIN in $CAMPUS_DIRECT_DOMAINS; do
        timeout 3 nslookup "$DOMAIN" "$CAMPUS_DNS_IP" 2>/dev/null |
            awk '/^Address [0-9]*: / { print $3 }' |
            while IFS= read -r ADDRESS; do
                case "$ADDRESS" in
                    *.*.*.*)
                        ROUTE="$ADDRESS/32"
                        ip route replace "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1
                        grep -Fqx "$ROUTE" "$CAMPUS_ROUTES_FILE" 2>/dev/null || printf '%s\n' "$ROUTE" >> "$CAMPUS_ROUTES_FILE"
                        ;;
                esac
            done
    done

    # Restore/publish the IPv4-only Blinkit answers before resolving local
    # public exceptions, including after a reboot or a tunnel teardown.
    sh "$DIR/refresh_blinkit_dns.sh" || echo "[WARNING] Blinkit DNS refresh deferred."

    # Selected public app endpoints use direct WAN egress to avoid WARP/shared
    # proxy reputation checks. Resolve through the router resolver and refresh
    # the host-route set every time the tunnel is (re)applied.
    if [ -f "$DIRECT_PUBLIC_ROUTES_FILE" ]; then
        while IFS= read -r ROUTE; do
            [ -n "$ROUTE" ] && ip route del "$ROUTE" 2>/dev/null || true
        done < "$DIRECT_PUBLIC_ROUTES_FILE"
    fi
    : > "$DIRECT_PUBLIC_ROUTES_FILE"
    for DOMAIN in $DIRECT_PUBLIC_DOMAINS; do
        timeout 3 nslookup "$DOMAIN" 127.0.0.1 2>/dev/null |
            awk '/^Address [0-9]*: / { print $3 }' |
            while IFS= read -r ADDRESS; do
                case "$ADDRESS" in
                    *.*.*.*)
                        ROUTE="$ADDRESS/32"
                        ip route replace "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1
                        grep -Fqx "$ROUTE" "$DIRECT_PUBLIC_ROUTES_FILE" 2>/dev/null || printf '%s\n' "$ROUTE" >> "$DIRECT_PUBLIC_ROUTES_FILE"
                        ;;
                esac
            done
    done
fi

# IPv4 NAT + forwarding through tun0
iptables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o "$TUN_IF" -j MASQUERADE
iptables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
iptables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV4_MSS" 2>/dev/null || iptables -t mangle -I FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV4_MSS"
# fw3 filters input only from br-lan and eth0: drop new connections arriving
# through the tunnel (replies are not NEW). A safeguard, so it never fails the
# start. stop_tunnel.sh keeps it: it matches nothing without tun0, and the next
# start then has no window without it.
iptables -C INPUT -i "$TUN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null || iptables -I INPUT -i "$TUN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null || echo "[WARNING] Could not add the iptables rule dropping new inbound connections on $TUN_IF."

ip route del default dev "$TUN_IF" 2>/dev/null || true
ip route add default dev "$TUN_IF" metric 5
ip route flush cache

# --- IPv6: all through tun0 ---
ip6tables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null || ip6tables -t nat -I POSTROUTING -o "$TUN_IF" -j MASQUERADE
ip6tables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || ip6tables -I FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
ip6tables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -I FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ip6tables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -I FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
ip6tables -t mangle -C FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV6_MSS" 2>/dev/null || ip6tables -t mangle -I FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV6_MSS" 2>/dev/null
ip6tables -C INPUT -i "$TUN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null || ip6tables -I INPUT -i "$TUN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null || echo "[WARNING] Could not add the ip6tables rule dropping new inbound connections on $TUN_IF."

ip -6 route add default dev "$TUN_IF" metric 5 2>/dev/null || ip -6 route replace default dev "$TUN_IF" metric 5

# Refresh LAN router advertisements after tun0 and its IPv6 default exist so
# clients immediately install their IPv6 default route after any manual start.
/etc/init.d/odhcpd restart 2>/dev/null || true

sh "$DIR/google_wan_policy.sh" || echo "[WARNING] Google WAN policy needs repair."

echo "[SUCCESS] Full tunnel active: public IPv4/IPv6 via tun0; campus IPv4 via eth0 (QUIC CC: $WARP_CC)."

trap - EXIT INT TERM
exit 0

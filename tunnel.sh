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
. "$DIR/defaults.sh"

WARP_CC="${WARP_CC:-cubic}"
# Datagrams the client may queue before it pauses TUN reads; 0 leaves it off.
WARP_TUN_BACKPRESSURE="${WARP_TUN_BACKPRESSURE:-0}"
# The client's CoDel target, in ms, for upload datagrams waiting to be sent;
# 0 leaves it off.
WARP_UPLOAD_CODEL="${WARP_UPLOAD_CODEL:-0}"
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

# Install host routes for the names that resolve now, without removing any.
# Deleting first moved those hosts onto WARP until they resolved again (tun0 is
# already the default when a running client is reused), and a failed lookup lost
# its route. ensure_network.sh's refresher is the only one that removes routes:
# stale ones, once every name resolves, and never one another refresher lists.
# These routes are optional, so a failure warns instead of failing the start.
add_host_routes() {
    for DOMAIN in $1; do
        ADDRESSES="$(timeout 3 nslookup "$DOMAIN" "$2" 2>/dev/null |
            awk '/^Address [0-9]+: / && $3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $3}')"
        for ADDRESS in $ADDRESSES; do
            if ip route replace "$ADDRESS/32" via "$DEFAULT_GW" dev "$WAN_IF" metric 1 2>/dev/null; then
                grep -Fqx "$ADDRESS/32" "$3" 2>/dev/null || printf '%s\n' "$ADDRESS/32" >> "$3"
            else
                echo "[WARNING] Could not install the host route $ADDRESS/32 for $DOMAIN."
            fi
        done
    done
}
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
SUPPORTS_SYSLOG=0
SUPPORTS_BACKPRESSURE=0
SUPPORTS_UPLOAD_CODEL=0
echo "$NATIVETUN_HELP" | grep -q 'congestion-control' && SUPPORTS_CC=1
echo "$NATIVETUN_HELP" | grep -q 'ready-file' && SUPPORTS_READY=1
echo "$NATIVETUN_HELP" | grep -q -- '--syslog' && SUPPORTS_SYSLOG=1
echo "$NATIVETUN_HELP" | grep -q -- '--tun-backpressure' && SUPPORTS_BACKPRESSURE=1
echo "$NATIVETUN_HELP" | grep -q -- '--upload-codel' && SUPPORTS_UPLOAD_CODEL=1

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
    # Keep the client's output off persistent flash. With --syslog its
    # connection events (and why a session ended) go to the RAM log instead:
    # logread -e usque-rs. Liveness checks are ensure_network.sh's job.
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
    if [ "$SUPPORTS_SYSLOG" -eq 1 ]; then
        set -- "$@" --syslog
    else
        echo "[WARNING] This usque-rs binary cannot log connection events."
    fi
    case "$WARP_TUN_BACKPRESSURE" in
        0) ;;
        ''|*[!0-9]*) echo "[WARNING] Ignoring WARP_TUN_BACKPRESSURE=$WARP_TUN_BACKPRESSURE: not a number." ;;
        *)
            if [ "$SUPPORTS_BACKPRESSURE" -eq 1 ]; then
                set -- "$@" --tun-backpressure "$WARP_TUN_BACKPRESSURE"
            else
                echo "[WARNING] This usque-rs binary does not support TUN-read backpressure."
            fi
            ;;
    esac
    # A typo must not stop the client from starting, so only 1-999 ms is passed.
    case "$WARP_UPLOAD_CODEL" in
        0) ;;
        [1-9]|[1-9][0-9]|[1-9][0-9][0-9])
            if [ "$SUPPORTS_UPLOAD_CODEL" -eq 1 ]; then
                set -- "$@" --upload-codel "$WARP_UPLOAD_CODEL"
            else
                echo "[WARNING] This usque-rs binary does not support the upload CoDel."
            fi
            ;;
        *) echo "[WARNING] Ignoring WARP_UPLOAD_CODEL=$WARP_UPLOAD_CODEL: not a number of milliseconds from 1 to 999." ;;
    esac
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

# The WAN's own gateway: the first other default can belong to another uplink.
DEFAULT_GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"

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
    # resulting IPv4 host routes off WARP.
    add_host_routes "$CAMPUS_DIRECT_DOMAINS" "$CAMPUS_DNS_IP" "$CAMPUS_ROUTES_FILE"

    # Restore/publish the IPv4-only Blinkit answers before resolving local
    # public exceptions, including after a reboot or a tunnel teardown.
    sh "$DIR/refresh_blinkit_dns.sh" || echo "[WARNING] Blinkit DNS refresh deferred."

    # Selected public app endpoints use direct WAN egress to avoid WARP/shared
    # proxy reputation checks. Resolve through the router resolver every time
    # the tunnel is (re)applied.
    add_host_routes "$DIRECT_PUBLIC_DOMAINS" 127.0.0.1 "$DIRECT_PUBLIC_ROUTES_FILE"
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

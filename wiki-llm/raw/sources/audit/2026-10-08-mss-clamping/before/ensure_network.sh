#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
LOCK_DIR="$DIR/.ensure_network.lock"
LOCK_OWNER_FILE="$LOCK_DIR/owner"
EXECUTABLE="$DIR/usque-rs"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file ensure)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

WAN_IF="${WAN_IF:-eth0}"
WAN_UCI_IFACE="${WAN_UCI_IFACE:-wan}"
LAN_IF="${LAN_IF:-br-lan}"
LAN_SUBNET="${LAN_SUBNET:-192.168.8.0/24}"
TUN_IF="${TUN_IF:-tun0}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_DOMAINS="${CAMPUS_DOMAINS:-internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
CAMPUS_DIRECT_DOMAINS="${CAMPUS_DIRECT_DOMAINS:-www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
DIRECT_PUBLIC_DOMAINS="${DIRECT_PUBLIC_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com o1069899.ingest.us.sentry.io gemini.google.com game.clashroyaleapp.com id.supercell.com init.mkt.supercell.com o315582.ingest.sentry.io clashroyale.com www.clashroyale.com}"
BLINKIT_IPV4_DOMAINS="${BLINKIT_IPV4_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com}"
BLINKIT_HOSTS_DIR="${BLINKIT_HOSTS_DIR:-/etc/router-script/blinkit-hosts}"
DIRECT_PUBLIC_ROUTES_FILE="${DIRECT_PUBLIC_ROUTES_FILE:-/tmp/router-script-direct-public-host-routes}"
GAME_SESSION_PORTS="${GAME_SESSION_PORTS:-9339}"
GAME_SESSION_ROUTES_FILE="${GAME_SESSION_ROUTES_FILE:-/tmp/router-script-game-session-host-routes}"
GAME_POLICY_TABLE="${GAME_POLICY_TABLE:-101}"
GAME_POLICY_PRIORITY="${GAME_POLICY_PRIORITY:-700}"
GAME_POLICY_MARK="${GAME_POLICY_MARK:-0x40000}"
GAME_POLICY_MASK="${GAME_POLICY_MASK:-0xf0000}"
LAN_IP6IFACEID="${LAN_IP6IFACEID:-::1}"
LAN_RA_DEFAULT="${LAN_RA_DEFAULT:-2}"
LAN_IPV6_RETRY_FILE="${LAN_IPV6_RETRY_FILE:-/tmp/router-script-lan-ipv6-retry-after}"
LAN_IPV6_RETRY_COOLDOWN="${LAN_IPV6_RETRY_COOLDOWN:-300}"
WIFI_COUNTRY="${WIFI_COUNTRY:-IN}"
WIFI_2G_DEVICE="${WIFI_2G_DEVICE:-mt798111}"
WIFI_5G_DEVICE="${WIFI_5G_DEVICE:-mt798112}"
WIFI_2G_HTMODE="${WIFI_2G_HTMODE:-HE20}"
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE80}"
TUNNEL_RETRY_FILE="${TUNNEL_RETRY_FILE:-/tmp/router-script-tunnel-retry-after}"
TUNNEL_RETRY_COOLDOWN="${TUNNEL_RETRY_COOLDOWN:-300}"
TMP_MAX_USED_PERCENT="${TMP_MAX_USED_PERCENT:-90}"
INTERACTIVE_LOGIN_MARKER="${INTERACTIVE_LOGIN_MARKER:-/tmp/router-script-interactive-login-required}"
INTERACTIVE_RETRY_SECONDS="${INTERACTIVE_RETRY_SECONDS:-300}"
WARP_READY_FILE="${WARP_READY_FILE:-/tmp/router-script-warp-ready}"
INTERNET_PROBE_URLS="${INTERNET_PROBE_URLS:-https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204}"
DIRECT_PROBE_CONNECT_TIMEOUT="${DIRECT_PROBE_CONNECT_TIMEOUT:-2}"
DIRECT_PROBE_MAX_TIME="${DIRECT_PROBE_MAX_TIME:-4}"
DIRECT_CONFIRM_DELAY="${DIRECT_CONFIRM_DELAY:-2}"
TUNNEL_CONFIRM_DELAY="${TUNNEL_CONFIRM_DELAY:-3}"
OVERLAY_WARN_PERCENT="${OVERLAY_WARN_PERCENT:-90}"
GAME_MODE_MARKER="${GAME_MODE_MARKER:-/tmp/router-script-game-mode}"

# DNS servers expected by the new config
DNS_SERVERS="8.8.8.8 8.8.4.4 $CAMPUS_DNS_IP 127.0.0.1#5453"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

cleanup() {
    if [ "$(cat "$LOCK_OWNER_FILE" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$LOCK_OWNER_FILE"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

LOCK_MAX_AGE="${LOCK_MAX_AGE:-180}"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -d "$LOCK_DIR" ]; then
        LOCK_OWNER="$(cat "$LOCK_OWNER_FILE" 2>/dev/null || true)"
        case "$LOCK_OWNER" in
            ''|*[!0-9]*) LOCK_OWNER_ALIVE=0 ;;
            *)
                if kill -0 "$LOCK_OWNER" 2>/dev/null \
                    && tr '\000' ' ' < "/proc/$LOCK_OWNER/cmdline" 2>/dev/null | grep -q 'ensure_network.sh'; then
                    LOCK_OWNER_ALIVE=1
                else
                    LOCK_OWNER_ALIVE=0
                fi
                ;;
        esac
        if [ "$LOCK_OWNER_ALIVE" -eq 1 ]; then
            log "Skipped: health check PID $LOCK_OWNER owns the maintenance lock."
            exit 0
        fi

        LOCK_AGE=$(( $(date +%s) - $(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0) ))
        if [ -n "$LOCK_OWNER" ] || [ "$LOCK_AGE" -gt "$LOCK_MAX_AGE" ]; then
            log "WARNING: Stale lock detected (age: ${LOCK_AGE}s). Removing and proceeding."
            rm -f "$LOCK_OWNER_FILE"
            if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
                log "Skipped: failed to acquire the health-check lock after stale-lock cleanup."
                exit 0
            fi
        else
            log "Skipped: another ensure_network.sh run is still active."
            exit 0
        fi
    else
        log "Skipped: another ensure_network.sh run is still active."
        exit 0
    fi
fi

printf '%s\n' "$$" > "$LOCK_OWNER_FILE"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Health check functions ---

internet_v4_ok() {
    for URL in $INTERNET_PROBE_URLS; do
        CODE="$(curl -4 -sS \
            --interface "$WAN_IF" \
            --connect-timeout "$DIRECT_PROBE_CONNECT_TIMEOUT" \
            --max-time "$DIRECT_PROBE_MAX_TIME" \
            -o /dev/null \
            -w '%{http_code}' \
            "$URL" 2>/dev/null || true)"
        [ "$CODE" = "204" ] && return 0
    done
    return 1
}

tunnel_internet_v4_ok() {
    for URL in $INTERNET_PROBE_URLS; do
        CODE="$(curl -4 -sS --interface "$TUN_IF" --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true)"
        [ "$CODE" = "204" ] && return 0
    done
    return 1
}

tunnel_internet_v6_ok() {
    for URL in $INTERNET_PROBE_URLS; do
        CODE="$(curl -6 -sS --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true)"
        [ "$CODE" = "204" ] && return 0
    done
    return 1
}

wan_ipv4_ok() {
    ifstatus "$WAN_UCI_IFACE" 2>/dev/null | grep -q '"address"[[:space:]]*:[[:space:]]*"'
}

wan_link_ok() {
    [ "$(cat "/sys/class/net/$WAN_IF/carrier" 2>/dev/null || echo 0)" = "1" ]
}

recover_wan() {
    log "Stopping tunnel and cycling $WAN_UCI_IFACE to recover the WAN lease."
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    ifdown "$WAN_UCI_IFACE" >> "$LOG_FILE" 2>&1 || true
    ifup "$WAN_UCI_IFACE" >> "$LOG_FILE" 2>&1 || true
    sleep 10
}

dns_config_ok() {
    sh "$DIR/google_wan_policy.sh" check-dns || return 1
    # Verify dnsmasq has strict-order and the expected servers
    [ "$(uci -q get dhcp.@dnsmasq[0].strictorder 2>/dev/null || echo "")" = "1" ] || return 1
    [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo "")" = "1" ] || return 1

    # Check all DNS servers are present in dnsmasq server list
    CURRENT_SERVERS="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || echo "")"
    for SERVER in $DNS_SERVERS; do
        echo "$CURRENT_SERVERS" | grep -Fq "$SERVER" || return 1
    done

    # Check campus domain forwarding
    for DOMAIN in $CAMPUS_DOMAINS; do
        echo "$CURRENT_SERVERS" | grep -Fq "/$DOMAIN/$CAMPUS_DNS_IP" || return 1
    done

    for DOMAIN in $BLINKIT_IPV4_DOMAINS; do
        printf '%s\n' "$CURRENT_SERVERS" | tr ' ' '\n' | grep -Fxq "/$DOMAIN/" || return 1
    done
    uci -q get dhcp.@dnsmasq[0].addnhosts | tr ' ' '\n' | grep -Fxq "$BLINKIT_HOSTS_DIR" || return 1

    # Portal/SSO local pins must survive UCI drift (campus DNS outage path).
    CURRENT_ADDRESSES="$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || echo "")"
    echo "$CURRENT_ADDRESSES" | grep -Fq "/internet.iitb.ac.in/${PORTAL_IP:-10.201.250.201}" || return 1
    echo "$CURRENT_ADDRESSES" | grep -Fq "/sso.iitb.ac.in/${SSO_IP:-10.200.1.100}" || return 1

    # Check dnscrypt-proxy block_ipv6 and listen port (must not steal :53).
    [ -f "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml" ] || return 1
    grep -Eq "^block_ipv6[[:space:]]*= *false$" "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml" || return 1
    grep -Eq "^listen_addresses[[:space:]]*=.*127\.0\.0\.1:5453" "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml" || return 1

    return 0
}

wifi_config_ok() {
    [ "$(uci -q get "wireless.$WIFI_2G_DEVICE.country" 2>/dev/null || echo "")" = "$WIFI_COUNTRY" ] || return 1
    [ "$(uci -q get "wireless.$WIFI_5G_DEVICE.country" 2>/dev/null || echo "")" = "$WIFI_COUNTRY" ] || return 1
    [ "$(uci -q get "wireless.$WIFI_2G_DEVICE.htmode" 2>/dev/null || echo "")" = "$WIFI_2G_HTMODE" ] || return 1
    [ "$(uci -q get "wireless.$WIFI_5G_DEVICE.htmode" 2>/dev/null || echo "")" = "$WIFI_5G_HTMODE" ] || return 1
}

wifi_runtime_ok() {
    STATUS="$(ubus call network.wireless status 2>/dev/null || true)"
    [ "$(printf '%s' "$STATUS" | jsonfilter -e "@.$WIFI_2G_DEVICE.up" 2>/dev/null)" = "true" ] || return 1
    [ "$(printf '%s' "$STATUS" | jsonfilter -e "@.$WIFI_5G_DEVICE.up" 2>/dev/null)" = "true" ]
}

dns_runtime_ok() {
    pidof dnsmasq >/dev/null 2>&1 || return 1
    timeout 8 nslookup internet.iitb.ac.in 127.0.0.1 2>/dev/null | grep -q 'Address [0-9]*: 10\.'
}

lan_ipv6_config_ok() {
    if [ ! -f "$GAME_MODE_MARKER" ]; then
        [ "$(uci -q get dhcp.@dnsmasq[0].filter_aaaa 2>/dev/null || echo "")" = "0" ] || return 1
    fi
    [ "$(uci -q get dhcp.lan.ra 2>/dev/null || echo "")" = "server" ] || return 1
    [ "$(uci -q get dhcp.lan.ra_slaac 2>/dev/null || echo "")" = "1" ] || return 1
    [ "$(uci -q get dhcp.lan.dhcpv6 2>/dev/null || echo "")" = "server" ] || return 1
    [ "$(uci -q get dhcp.lan.ra_default 2>/dev/null || echo "")" = "$LAN_RA_DEFAULT" ] || return 1
    [ "$(uci -q get network.lan.ip6ifaceid 2>/dev/null || echo "")" = "$LAN_IP6IFACEID" ] || return 1
    ip -6 addr show dev "$LAN_IF" 2>/dev/null | grep -q "scope global" || return 1
}

lan_ipv6_retry_deferred() {
    [ -f "$LAN_IPV6_RETRY_FILE" ] || return 1
    RETRY_AFTER="$(cat "$LAN_IPV6_RETRY_FILE" 2>/dev/null || echo 0)"
    case "$RETRY_AFTER" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(date +%s)" -lt "$RETRY_AFTER" ]
}

defer_lan_ipv6_retry() {
    printf '%s\n' "$(( $(date +%s) + LAN_IPV6_RETRY_COOLDOWN ))" > "$LAN_IPV6_RETRY_FILE"
}

tunnel_process_ok() {
    pidof "$(basename "$EXECUTABLE")" >/dev/null 2>&1
}

tunnel_routes_ok() {
    ip -4 route show default 2>/dev/null | grep -q "dev $TUN_IF" || return 1
    ip -6 route show default 2>/dev/null | grep -q "dev $TUN_IF" || return 1
}

campus_core_route_ok() {
    ip route get "$CAMPUS_DNS_IP" 2>/dev/null | grep -q "dev $WAN_IF"
}

# Optional DNS exceptions are maintenance, not tunnel liveness. Resolve once:
# querying again can return a different CDN address and falsely restart WARP.
refresh_host_routes() (
    DOMAINS="$1"
    RESOLVER="$2"
    ROUTES_FILE="$3"
    DEFAULT_GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
    [ -n "$DEFAULT_GW" ] || return 1
    TMP_ROUTES="$(mktemp "${ROUTES_FILE}.XXXXXX")" || return 1
    trap 'rm -f "$TMP_ROUTES"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ALL_RESOLVED=1
    for DOMAIN in $DOMAINS; do
        ADDRESSES="$(timeout 3 nslookup "$DOMAIN" "$RESOLVER" 2>/dev/null |
            awk '/^Address [0-9]+: / && $3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $3}')"
        if [ -z "$ADDRESSES" ]; then
            ALL_RESOLVED=0
            continue
        fi
        for ADDRESS in $ADDRESSES; do
            ROUTE="$ADDRESS/32"
            if ip route replace "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1; then
                grep -Fqx "$ROUTE" "$TMP_ROUTES" || printf '%s\n' "$ROUTE" >> "$TMP_ROUTES"
            else
                ALL_RESOLVED=0
            fi
        done
    done
    if [ -f "$ROUTES_FILE" ]; then
        while IFS= read -r ROUTE; do
            [ -n "$ROUTE" ] || continue
            grep -Fqx "$ROUTE" "$TMP_ROUTES" && continue
            if [ "$ALL_RESOLVED" -eq 1 ]; then
                ip route del "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1 2>/dev/null || true
            else
                # A partial DNS outage must not remove another domain's route.
                printf '%s\n' "$ROUTE" >> "$TMP_ROUTES"
            fi
        done < "$ROUTES_FILE"
    fi
    mv "$TMP_ROUTES" "$ROUTES_FILE"
)

ensure_game_session_policy() {
    DEFAULT_GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
    [ -n "$DEFAULT_GW" ] || return 1

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
}

refresh_optional_routes() {
    ensure_game_session_policy ||
        log "Game-session policy refresh deferred; preserving the running tunnel."
    refresh_host_routes "$CAMPUS_DIRECT_DOMAINS" "$CAMPUS_DNS_IP" "${CAMPUS_ROUTES_FILE:-/tmp/router-script-campus-host-routes}" ||
        log "Campus host-route refresh deferred; preserving the running tunnel."
    refresh_host_routes "$DIRECT_PUBLIC_DOMAINS" 127.0.0.1 "$DIRECT_PUBLIC_ROUTES_FILE" ||
        log "Public host-route refresh deferred; preserving the running tunnel."
    refresh_game_session_routes ||
        log "Game-session host-route refresh deferred; preserving the running tunnel."
}

refresh_game_session_routes() {
    DEFAULT_GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
    [ -n "$DEFAULT_GW" ] || return 1
    command -v conntrack >/dev/null 2>&1 || return 0

    TMP_ROUTES="$(mktemp "${GAME_SESSION_ROUTES_FILE}.XXXXXX")" || return 1
    FOUND=0
    for PORT in $GAME_SESSION_PORTS; do
        ADDRESSES="$(conntrack -L 2>/dev/null |
            awk -v port="$PORT" '
                /src=192\.168\.8\.[0-9]+/ && $0 ~ ("dport=" port "([[:space:]]|$)") {
                    for (i = 1; i <= NF; i++)
                        if ($i ~ /^dst=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                            sub(/^dst=/, "", $i); print $i; break
                        }
                }
            ' | sort -u)"
        for ADDRESS in $ADDRESSES; do
            [ -n "$ADDRESS" ] || continue
            ROUTE="$ADDRESS/32"
            if ip route replace "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1; then
                FOUND=1
                grep -Fqx "$ROUTE" "$TMP_ROUTES" 2>/dev/null || printf '%s\n' "$ROUTE" >> "$TMP_ROUTES"
            fi
        done
    done

    if [ "$FOUND" -eq 1 ]; then
        if [ -f "$GAME_SESSION_ROUTES_FILE" ]; then
            while IFS= read -r ROUTE; do
                [ -n "$ROUTE" ] || continue
                grep -Fqx "$ROUTE" "$TMP_ROUTES" 2>/dev/null && continue
                ip route del "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1 2>/dev/null || true
            done < "$GAME_SESSION_ROUTES_FILE"
        fi
        mv "$TMP_ROUTES" "$GAME_SESSION_ROUTES_FILE"
    else
        rm -f "$TMP_ROUTES"
    fi
    return 0
}

tunnel_ready_ok() {
    [ -s "$WARP_READY_FILE" ] && return 0
    "$EXECUTABLE" nativetun --help 2>&1 | grep -q 'ready-file' && return 1
    return 0
}

nat_rules_ok() {
    iptables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null || return 1
    ip6tables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null || return 1
}

runtime_resources_ok() {
    TMP_USED="$(df /tmp 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
    case "$TMP_USED" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$TMP_USED" -lt "$TMP_MAX_USED_PERCENT" ]
}

overlay_usage_percent() {
    df /overlay 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}'
}

maintain_persistent_storage() {
    OVERLAY_USED="$(overlay_usage_percent)"
    case "$OVERLAY_USED" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$OVERLAY_USED" -lt "$OVERLAY_WARN_PERCENT" ] && return 0

    log "Persistent storage warning: /overlay is ${OVERLAY_USED}% used. Pruning bounded project logs and diagnostics."
    sh "$DIR/rotate_logs.sh" >> "$LOG_FILE" 2>&1 || true
    OVERLAY_USED="$(overlay_usage_percent)"
    log "Persistent storage after project maintenance: /overlay is ${OVERLAY_USED:-unknown}% used."
}

tunnel_retry_deferred() {
    [ -f "$TUNNEL_RETRY_FILE" ] || return 1
    RETRY_AFTER="$(cat "$TUNNEL_RETRY_FILE" 2>/dev/null || echo 0)"
    case "$RETRY_AFTER" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(date +%s)" -lt "$RETRY_AFTER" ]
}

defer_tunnel_retry() {
    RETRY_AFTER=$(( $(date +%s) + TUNNEL_RETRY_COOLDOWN ))
    printf '%s\n' "$RETRY_AFTER" > "$TUNNEL_RETRY_FILE"
}

tunnel_healthy() {
    TUNNEL_FAILURE_REASON="process missing"
    tunnel_process_ok || return 1
    TUNNEL_FAILURE_REASON="TUN interface missing"
    ip link show dev "$TUN_IF" >/dev/null 2>&1 || return 1
    TUNNEL_FAILURE_REASON="CONNECT-IP not ready (client may be reconnecting)"
    tunnel_ready_ok || return 1
    TUNNEL_FAILURE_REASON="default route missing"
    tunnel_routes_ok || return 1
    TUNNEL_FAILURE_REASON="campus underlay route missing"
    campus_core_route_ok || return 1
    TUNNEL_FAILURE_REASON="NAT rule missing"
    nat_rules_ok || return 1
    TUNNEL_FAILURE_REASON="both tunnel IPv4 HTTP probes failed"
    tunnel_internet_v4_ok || return 1
    TUNNEL_FAILURE_REASON=""
}

tunnel_healthy_confirmed() {
    tunnel_healthy && return 0
    log "Tunnel check failed: $TUNNEL_FAILURE_REASON. Confirming before restart."
    # A missing process/interface cannot recover on its own. A live client's
    # reconnect or brief packet loss deserves a second observation.
    tunnel_process_ok || return 1
    ip link show dev "$TUN_IF" >/dev/null 2>&1 || return 1
    sleep "$TUNNEL_CONFIRM_DELAY"
    tunnel_healthy
}

# --- Main health check pipeline ---

# Repair Google policy separately; failure must never restart a working WARP.
sh "$DIR/google_wan_policy.sh" >> "$LOG_FILE" 2>&1 ||
    log "Google WAN policy deferred until the WAN is available."

log "Starting health check."

maintain_persistent_storage

if ! wifi_config_ok; then
    log "Wi-Fi stability configuration drift detected. Reapplying configure_wifi.sh."
    sh "$DIR/configure_wifi.sh" >> "$LOG_FILE" 2>&1 || log "configure_wifi.sh failed."
    if ! wifi_config_ok; then
        log "Wi-Fi configuration remains invalid after repair. Collecting diagnostics."
        sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
        exit 1
    fi
fi

if ! wifi_runtime_ok; then
    log "Wi-Fi runtime is down despite valid configuration. Reloading radios."
    wifi reload >> "$LOG_FILE" 2>&1 || true
    sleep 5
    if ! wifi_runtime_ok; then
        log "Wi-Fi runtime remains down after reload. Collecting diagnostics."
        sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
        exit 1
    fi
fi

if ! dns_config_ok; then
    log "DNS configuration drift detected. Reapplying configure_dns.sh."
    sh "$DIR/configure_dns.sh" >> "$LOG_FILE" 2>&1 || log "configure_dns.sh failed."
    if ! dns_config_ok; then
        log "DNS configuration remains invalid after repair. Collecting diagnostics."
        sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
        exit 1
    fi
fi

if ! dns_runtime_ok; then
    log "dnsmasq runtime or campus resolution failed. Reapplying DNS configuration."
    sh "$DIR/configure_dns.sh" >> "$LOG_FILE" 2>&1 || log "configure_dns.sh failed during runtime recovery."
    if ! dns_runtime_ok; then
        log "DNS runtime remains unhealthy after repair. Collecting diagnostics."
        sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
        exit 1
    fi
fi

if lan_ipv6_config_ok; then
    rm -f "$LAN_IPV6_RETRY_FILE"
elif lan_ipv6_retry_deferred; then
    log "LAN IPv6 remains degraded; repair cooldown is active. Continuing IPv4 and tunnel recovery."
else
    log "LAN IPv6 configuration drift detected. Reapplying configure_lan_ipv6.sh."
    sh "$DIR/configure_lan_ipv6.sh" >> "$LOG_FILE" 2>&1 || log "configure_lan_ipv6.sh failed."
    if lan_ipv6_config_ok; then
        rm -f "$LAN_IPV6_RETRY_FILE"
        log "LAN IPv6 configuration recovered."
    else
        log "LAN IPv6 remains invalid after repair. Capturing evidence once and continuing IPv4 and tunnel recovery."
        sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
        defer_lan_ipv6_retry
    fi
fi

if ! wan_ipv4_ok || ! wan_link_ok; then
    log "WAN IPv4 lease or Ethernet carrier is missing."
    recover_wan
fi

if ! wan_ipv4_ok || ! wan_link_ok; then
    log "WAN IPv4 lease or carrier is still missing after recovery. Collecting diagnostics."
    sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
    exit 1
fi

if ! campus_core_route_ok; then
    log "Campus DNS route is not using $WAN_IF."
    recover_wan
fi

if ! campus_core_route_ok; then
    log "Campus DNS route is still incorrect after WAN recovery. Collecting diagnostics."
    sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
    exit 1
fi

if ! internet_v4_ok && [ -f "$INTERACTIVE_LOGIN_MARKER" ]; then
    MARKER_TIME="$(date -r "$INTERACTIVE_LOGIN_MARKER" +%s 2>/dev/null || echo 0)"
    MARKER_AGE=$(( $(date +%s) - MARKER_TIME ))
    if [ "$MARKER_AGE" -lt "$INTERACTIVE_RETRY_SECONDS" ]; then
        log "Interactive IITB login is pending; deferring token retry for $((INTERACTIVE_RETRY_SECONDS - MARKER_AGE))s."
        if tunnel_process_ok || ip -4 route show default 2>/dev/null | grep -q "dev $TUN_IF"; then
            sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        fi
        exit 0
    fi
    log "Interactive-login retry interval elapsed; retrying the access token."
    rm -f "$INTERACTIVE_LOGIN_MARKER"
fi

PORTAL_RECOVERY_ATTEMPTED=0
if ! internet_v4_ok; then
    log "IPv4 internet check failed once. Confirming before portal recovery."
    sleep "$DIRECT_CONFIRM_DELAY"
    if ! internet_v4_ok; then
        log "IPv4 internet check failed twice. Running login.sh."
        PORTAL_RECOVERY_ATTEMPTED=1
        sh "$DIR/login.sh" >> "$LOG_FILE" 2>&1 || true
    fi
    if [ -f "$INTERACTIVE_LOGIN_MARKER" ]; then
        log "Interactive IITB SSO login is required; keeping direct WAN fallback active."
        if tunnel_process_ok || ip -4 route show default 2>/dev/null | grep -q "dev $TUN_IF"; then
            sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        fi
        exit 0
    fi
    [ "$PORTAL_RECOVERY_ATTEMPTED" -eq 1 ] && sleep 5
fi

rm -f "$INTERACTIVE_LOGIN_MARKER"

if ! internet_v4_ok; then
    log "IPv4 internet is still down after confirmation or login recovery."
    if tunnel_process_ok; then
        log "Stopping tunnel to allow traffic to fall back to direct WAN."
        sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
        sleep 3
        log "Retrying login after tunnel teardown."
        sh "$DIR/login.sh" >> "$LOG_FILE" 2>&1 || true
        sleep 5
    fi
    if ! internet_v4_ok; then
        log "IPv4 internet is still down after tunnel teardown. Collecting diagnostics."
        sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
        exit 1
    fi
    log "Internet recovered after tunnel teardown."
fi

if ! runtime_resources_ok; then
    log "Runtime storage pressure detected: /tmp is at or above ${TMP_MAX_USED_PERCENT}% usage. Falling back to direct WAN."
    sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    defer_tunnel_retry
    exit 1
fi

# Publish fresh Blinkit IPv4 answers only after their WAN routes exist.
sh "$DIR/refresh_blinkit_dns.sh" >> "$LOG_FILE" 2>&1 ||
    log "Blinkit DNS refresh deferred; preserving last known records."

if [ -f "$GAME_MODE_MARKER" ]; then
    # Competitive low-latency mode: keep direct WAN default. Do not re-promote
    # WARP or restart the tunnel just because tun0 is not the default.
    if internet_v4_ok; then
        log "Health check passed (game_mode: direct WAN preferred)."
        exit 0
    fi
    log "game_mode active but direct IPv4 failed; attempting portal recovery only."
    sh "$DIR/login.sh" >> "$LOG_FILE" 2>&1 || true
    if internet_v4_ok; then
        log "Health check passed (game_mode after login)."
        exit 0
    fi
    log "game_mode: direct IPv4 still down."
    exit 1
fi

if tunnel_healthy_confirmed; then
    refresh_optional_routes
    rm -f "$TUNNEL_RETRY_FILE"
    log "Health check passed."
    exit 0
fi

if tunnel_retry_deferred; then
    log "Tunnel retry is cooling down; keeping direct WAN fallback active."
    if tunnel_process_ok || ip -4 route show default 2>/dev/null | grep -q "dev $TUN_IF"; then
        sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    fi
    exit 0
fi

log "Tunnel health check failed: $TUNNEL_FAILURE_REASON. Restarting tunnel."
sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
sleep 10
log "Restarting odhcpd to refresh LAN IPv6 Router Advertisements."
/etc/init.d/odhcpd restart >> "$LOG_FILE" 2>&1 || true

if ! tunnel_healthy_confirmed; then
    log "Tunnel is still unhealthy after restart. Collecting diagnostics and enabling direct WAN fallback."
    sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    defer_tunnel_retry
    exit 1
fi

rm -f "$TUNNEL_RETRY_FILE"
refresh_optional_routes
log "Health check passed."

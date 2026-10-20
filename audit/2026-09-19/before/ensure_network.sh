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
TUN_IF="${TUN_IF:-tun0}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_DOMAINS="${CAMPUS_DOMAINS:-internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
CAMPUS_DIRECT_DOMAINS="${CAMPUS_DIRECT_DOMAINS:-www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
DIRECT_PUBLIC_DOMAINS="${DIRECT_PUBLIC_DOMAINS:-api3.blinkit.com jumbo.blinkit.com o1069899.ingest.us.sentry.io gemini.google.com}"
DIRECT_PUBLIC_ROUTES_FILE="${DIRECT_PUBLIC_ROUTES_FILE:-/tmp/router-script-direct-public-host-routes}"
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
TUNNEL_PERFORMANCE_PROBE_URL="${TUNNEL_PERFORMANCE_PROBE_URL:-https://www.google.com/generate_204}"
TUNNEL_MAX_PROBE_SECONDS="${TUNNEL_MAX_PROBE_SECONDS:-1.5}"
TUNNEL_PERFORMANCE_SAMPLES="${TUNNEL_PERFORMANCE_SAMPLES:-3}"
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
        CODE="$(curl -4 -sS --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true)"
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

tunnel_performance_ok() {
    SLOW_SAMPLES=0
    SAMPLE=0

    case "$TUNNEL_PERFORMANCE_SAMPLES" in
        ''|*[!0-9]*|0|1)
            log "Invalid TUNNEL_PERFORMANCE_SAMPLES=$TUNNEL_PERFORMANCE_SAMPLES; expected an integer of at least 2."
            return 1
            ;;
    esac

    while [ "$SAMPLE" -lt "$TUNNEL_PERFORMANCE_SAMPLES" ]; do
        RESULT="$(curl -4 -sS \
            --connect-timeout 4 \
            --max-time 10 \
            -o /dev/null \
            -w '%{http_code} %{time_total}' \
            "$TUNNEL_PERFORMANCE_PROBE_URL" 2>/dev/null || true)"
        CODE="${RESULT%% *}"
        ELAPSED="${RESULT#* }"

        if [ "$CODE" != "204" ] || ! awk \
            -v elapsed="$ELAPSED" \
            -v limit="$TUNNEL_MAX_PROBE_SECONDS" \
            'BEGIN { exit !(elapsed + 0 <= limit + 0) }'; then
            SLOW_SAMPLES=$((SLOW_SAMPLES + 1))
        fi

        SAMPLE=$((SAMPLE + 1))
    done

    # One transient slow response is tolerated. Two slow samples indicate a
    # persistently degraded tunnel even when HTTP eventually returns 204.
    if [ "$SLOW_SAMPLES" -ge 2 ]; then
        log "Tunnel performance degraded: $SLOW_SAMPLES/$TUNNEL_PERFORMANCE_SAMPLES probes exceeded ${TUNNEL_MAX_PROBE_SECONDS}s or failed."
        return 1
    fi
    return 0
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

campus_direct_routes_ok() {
    for DOMAIN in $CAMPUS_DIRECT_DOMAINS; do
        FOUND_ADDRESS=0
        for ADDRESS in $(nslookup "$DOMAIN" "$CAMPUS_DNS_IP" 2>/dev/null | awk '/^Address [0-9]*: / { print $3 }'); do
            case "$ADDRESS" in
                *.*.*.*)
                    FOUND_ADDRESS=1
                    ip route get "$ADDRESS" 2>/dev/null | grep -q "dev $WAN_IF" || return 1
                    ;;
            esac
        done
        # An optional site's transient DNS failure must not reset the WAN.
        # Existing static/private campus routes remain valid until DNS returns.
        [ "$FOUND_ADDRESS" -eq 0 ] && continue
    done

    return 0
}

direct_public_routes_ok() {
    for DOMAIN in $DIRECT_PUBLIC_DOMAINS; do
        FOUND_ADDRESS=0
        for ADDRESS in $(nslookup "$DOMAIN" 127.0.0.1 2>/dev/null | awk '/^Address [0-9]*: / { print $3 }'); do
            case "$ADDRESS" in
                *.*.*.*)
                    FOUND_ADDRESS=1
                    ip route get "$ADDRESS" 2>/dev/null | grep -q "dev $WAN_IF" || return 1
                    ;;
            esac
        done
        # A transient public DNS failure must not tear down the tunnel; the
        # next tunnel/health pass will refresh the host route.
        [ "$FOUND_ADDRESS" -eq 0 ] && continue
    done
    return 0
}

refresh_direct_public_routes() {
    DEFAULT_GW="$(ip route show default | grep -v "dev $TUN_IF" | head -n 1 | awk '/default/ {print $3}')"
    [ -n "$DEFAULT_GW" ] || return 1

    TMP_ROUTES="/tmp/router-script-direct-public-host-routes.$$"
    : > "$TMP_ROUTES"
    FOUND_ANY=0
    for DOMAIN in $DIRECT_PUBLIC_DOMAINS; do
        for ADDRESS in $(nslookup "$DOMAIN" 127.0.0.1 2>/dev/null | awk '/^Address [0-9]*: / { print $3 }'); do
            case "$ADDRESS" in
                *.*.*.*)
                    FOUND_ANY=1
                    ROUTE="$ADDRESS/32"
                    ip route replace "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1
                    grep -Fqx "$ROUTE" "$TMP_ROUTES" 2>/dev/null || printf '%s\n' "$ROUTE" >> "$TMP_ROUTES"
                    ;;
            esac
        done
    done

    # Keep the last known-good set across a transient DNS failure. Once at
    # least one answer is available, remove stale addresses atomically.
    if [ "$FOUND_ANY" -eq 1 ]; then
        if [ -f "$DIRECT_PUBLIC_ROUTES_FILE" ]; then
            while IFS= read -r ROUTE; do
                [ -n "$ROUTE" ] && grep -Fqx "$ROUTE" "$TMP_ROUTES" 2>/dev/null || ip route del "$ROUTE" 2>/dev/null || true
            done < "$DIRECT_PUBLIC_ROUTES_FILE"
        fi
        mv "$TMP_ROUTES" "$DIRECT_PUBLIC_ROUTES_FILE"
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
    tunnel_process_ok || return 1
    ip link show dev "$TUN_IF" >/dev/null 2>&1 || return 1
    tunnel_ready_ok || return 1
    tunnel_routes_ok || return 1
    campus_core_route_ok || return 1
    refresh_direct_public_routes || return 1
    campus_direct_routes_ok || return 1
    direct_public_routes_ok || return 1
    nat_rules_ok || return 1

    # Active validation: one IPv4 success is enough to keep the tunnel.
    # Avoid extra IPv6/latency probe storms every 30s — they compete with game
    # traffic on the single QUIC session and previously caused false restarts.
    tunnel_internet_v4_ok || return 1
}

# --- Main health check pipeline ---

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

if tunnel_healthy; then
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

log "Tunnel health check failed. Restarting tunnel."
sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
sh "$DIR/tunnel.sh" >> "$LOG_FILE" 2>&1 || true
sleep 10
log "Restarting odhcpd to refresh LAN IPv6 Router Advertisements."
/etc/init.d/odhcpd restart >> "$LOG_FILE" 2>&1 || true

if ! tunnel_healthy; then
    log "Tunnel is still unhealthy after restart. Collecting diagnostics and enabling direct WAN fallback."
    sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    defer_tunnel_retry
    exit 1
fi

rm -f "$TUNNEL_RETRY_FILE"
log "Health check passed."

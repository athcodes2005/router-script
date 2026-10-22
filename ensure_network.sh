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
TUN_IPV4_MSS="${TUN_IPV4_MSS:-1240}"
TUN_IPV6_MSS="${TUN_IPV6_MSS:-1220}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_NETS="${CAMPUS_NETS:-10.0.0.0/8 103.21.124.0/22}"
CAMPUS_DOMAINS="${CAMPUS_DOMAINS:-internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
CAMPUS_DIRECT_DOMAINS="${CAMPUS_DIRECT_DOMAINS:-www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
DIRECT_PUBLIC_DOMAINS="${DIRECT_PUBLIC_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com o1069899.ingest.us.sentry.io gemini.google.com game.clashroyaleapp.com id.supercell.com init.mkt.supercell.com o315582.ingest.sentry.io clashroyale.com www.clashroyale.com}"
BLINKIT_IPV4_DOMAINS="${BLINKIT_IPV4_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com}"
BLINKIT_HOSTS_DIR="${BLINKIT_HOSTS_DIR:-/etc/router-script/blinkit-hosts}"
CAMPUS_ROUTES_FILE="${CAMPUS_ROUTES_FILE:-/tmp/router-script-campus-host-routes}"
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
WIFI_REPAIR_RETRY_FILE="${WIFI_REPAIR_RETRY_FILE:-/tmp/router-script-wifi-repair-retry-after}"
DNS_CONFIG_RETRY_FILE="${DNS_CONFIG_RETRY_FILE:-/tmp/router-script-dns-config-retry-after}"
DNS_RUNTIME_RETRY_FILE="${DNS_RUNTIME_RETRY_FILE:-/tmp/router-script-dns-runtime-retry-after}"
STAGE_REPAIR_COOLDOWN="${STAGE_REPAIR_COOLDOWN:-300}"
DIAGNOSTICS_RETRY_DIR="${DIAGNOSTICS_RETRY_DIR:-/tmp/router-script-diagnostics-after}"
DIAGNOSTICS_COOLDOWN="${DIAGNOSTICS_COOLDOWN:-900}"
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
TUNNEL_SLOW_SECONDS="${TUNNEL_SLOW_SECONDS:-1.5}"
TUNNEL_SLOW_CHECKS="${TUNNEL_SLOW_CHECKS:-3}"
TUNNEL_SLOW_FILE="${TUNNEL_SLOW_FILE:-/tmp/router-script-tunnel-slow-count}"
ROUTE_PROBE_V4="${ROUTE_PROBE_V4:-1.1.1.1}"
ROUTE_PROBE_V6="${ROUTE_PROBE_V6:-2606:4700:4700::1111}"
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
        RESULT="$(curl -4 -sS --interface "$TUN_IF" --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code} %{time_total}' "$URL" 2>/dev/null || true)"
        TUNNEL_PROBE_TIME="${RESULT#* }"
        [ "${RESULT%% *}" = "204" ] && return 0
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

    # strict-order only helps if the upstreams come first, in this order, and
    # only the listed hosts may go to campus DNS (never the whole zone).
    printf '%s\n' "$CURRENT_SERVERS" | awk -v want="$DNS_SERVERS" -v dns="$CAMPUS_DNS_IP" -v allowed=" $CAMPUS_DOMAINS " '
        {
            n = split(want, w, " ")
            for (i = 1; i <= n; i++) if ($i != w[i]) bad = 1
            for (i = 1; i <= NF; i++) {
                parts = split($i, part, "/")
                if (parts < 3 || part[parts] != dns) continue
                for (j = 2; j < parts; j++) if (index(allowed, " " part[j] " ") == 0) bad = 1
            }
        }
        END { exit bad }' || return 1

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

# A disruptive repair that keeps failing runs at most once per cooldown rather
# than on every tick. Marker writes must never abort the pipeline.
retry_deferred() {
    [ -f "$1" ] || return 1
    RETRY_AFTER="$(cat "$1" 2>/dev/null || echo 0)"
    case "$RETRY_AFTER" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(date +%s)" -lt "$RETRY_AFTER" ]
}

defer_retry() {
    printf '%s\n' "$(( $(date +%s) + $2 ))" 2>/dev/null > "$1" || true
}

clear_retry() {
    [ ! -f "$1" ] || rm -f "$1"
}

# A persistent failure repeats every tick. Keep the incident's first snapshot
# rather than replacing the retained history with near-identical ones.
collect_diagnostics_once() {
    if retry_deferred "$DIAGNOSTICS_RETRY_DIR/$1"; then
        log "Diagnostics for $1 were captured recently; not taking another snapshot."
        return 0
    fi
    mkdir -p "$DIAGNOSTICS_RETRY_DIR" 2>/dev/null || true
    sh "$DIR/collect_diagnostics.sh" >> "$LOG_FILE" 2>&1 || true
    defer_retry "$DIAGNOSTICS_RETRY_DIR/$1" "$DIAGNOSTICS_COOLDOWN"
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

# Called only after the lease and carrier passed: the routing state is what is
# missing (e.g. an eth0 link flap flushed it while tun0 kept its default), so
# reinstall it. Cycling the WAN would release the lease and reset every flow.
repair_campus_routes() {
    DEFAULT_GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
    [ -n "$DEFAULT_GW" ] || return 1
    for NET in $CAMPUS_NETS; do
        ip route replace "$NET" via "$DEFAULT_GW" dev "$WAN_IF" metric 1 || return 1
    done
}

# The refreshers can share a /32 (a game server can also be a listed public
# name), so a route is deleted only once no other refresher's file lists it.
route_listed_elsewhere() {
    for FILE in "$CAMPUS_ROUTES_FILE" "$DIRECT_PUBLIC_ROUTES_FILE" "$GAME_SESSION_ROUTES_FILE"; do
        [ "$FILE" != "$2" ] || continue
        grep -Fqx "$1" "$FILE" 2>/dev/null && return 0
    done
    return 1
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
        # shellcheck disable=SC2094 # route_listed_elsewhere skips this file; nothing writes it here.
        while IFS= read -r ROUTE; do
            [ -n "$ROUTE" ] || continue
            grep -Fqx "$ROUTE" "$TMP_ROUTES" && continue
            if [ "$ALL_RESOLVED" -eq 1 ]; then
                route_listed_elsewhere "$ROUTE" "$ROUTES_FILE" ||
                    ip route del "$ROUTE" via "$DEFAULT_GW" dev "$WAN_IF" metric 1 2>/dev/null || true
            else
                # A partial DNS outage must not remove another domain's route.
                printf '%s\n' "$ROUTE" >> "$TMP_ROUTES"
            fi
        done < "$ROUTES_FILE"
    fi
    mv "$TMP_ROUTES" "$ROUTES_FILE"
)

# Intact means every rule the rebuild below adds is present, the restore rule
# is first and nothing else was added. Keep both rule lists in sync.
game_session_rules_intact() {
    EXPECTED=1
    iptables -t mangle -C GAME_SESSION_POLICY -m connmark ! --mark 0x0/"$GAME_POLICY_MASK" -j CONNMARK --restore-mark --nfmask "$GAME_POLICY_MASK" --ctmask "$GAME_POLICY_MASK" 2>/dev/null || return 1
    for PORT in $GAME_SESSION_PORTS; do
        EXPECTED=$((EXPECTED + 4))
        iptables -t mangle -C GAME_SESSION_POLICY -i "$LAN_IF" -p tcp -m tcp --dport "$PORT" -m conntrack --ctstate NEW -j MARK --set-xmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" 2>/dev/null || return 1
        iptables -t mangle -C GAME_SESSION_POLICY -i "$LAN_IF" -p tcp -m tcp --dport "$PORT" -m conntrack --ctstate NEW -j CONNMARK --save-mark --nfmask "$GAME_POLICY_MASK" --ctmask "$GAME_POLICY_MASK" 2>/dev/null || return 1
        iptables -t mangle -C GAME_SESSION_POLICY -i "$LAN_IF" -p udp -m udp --dport "$PORT" -m conntrack --ctstate NEW -j MARK --set-xmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" 2>/dev/null || return 1
        iptables -t mangle -C GAME_SESSION_POLICY -i "$LAN_IF" -p udp -m udp --dport "$PORT" -m conntrack --ctstate NEW -j CONNMARK --save-mark --nfmask "$GAME_POLICY_MASK" --ctmask "$GAME_POLICY_MASK" 2>/dev/null || return 1
    done
    RULES="$(iptables -t mangle -S GAME_SESSION_POLICY 2>/dev/null | grep -- '^-A ' || true)"
    [ "$(printf '%s\n' "$RULES" | grep -c -- '^-A ')" -eq "$EXPECTED" ] || return 1
    case "$(printf '%s\n' "$RULES" | sed -n '1p')" in
        *--restore-mark*) return 0 ;;
    esac
    return 1
}

ensure_game_session_policy() {
    DEFAULT_GW="$(ip -4 route show default dev "$WAN_IF" | awk '/via/ {print $3; exit}')"
    [ -n "$DEFAULT_GW" ] || return 1

    ip route replace "$LAN_SUBNET" dev "$LAN_IF" table "$GAME_POLICY_TABLE"
    ip route replace default via "$DEFAULT_GW" dev "$WAN_IF" table "$GAME_POLICY_TABLE"
    # Change rules only on drift: deleting and re-adding them every tick left
    # windows in which new game sessions went unmarked and stayed on WARP.
    if ! ip rule show | grep -Eq "^$GAME_POLICY_PRIORITY:.*fwmark $GAME_POLICY_MARK/$GAME_POLICY_MASK .*lookup $GAME_POLICY_TABLE"; then
        while ip rule del priority "$GAME_POLICY_PRIORITY" fwmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" table "$GAME_POLICY_TABLE" 2>/dev/null; do :; done
        ip rule add priority "$GAME_POLICY_PRIORITY" fwmark "$GAME_POLICY_MARK/$GAME_POLICY_MASK" table "$GAME_POLICY_TABLE"
    fi

    if ! game_session_rules_intact; then
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
    fi
    # The jump stays the first mangle PREROUTING rule, as before.
    if [ "$(iptables -t mangle -S PREROUTING 2>/dev/null | sed -n '2p')" != "-A PREROUTING -j GAME_SESSION_POLICY" ]; then
        while iptables -t mangle -C PREROUTING -j GAME_SESSION_POLICY 2>/dev/null; do
            iptables -t mangle -D PREROUTING -j GAME_SESSION_POLICY
        done
        iptables -t mangle -I PREROUTING 1 -j GAME_SESSION_POLICY
    fi
}

refresh_optional_routes() {
    ensure_game_session_policy ||
        log "Game-session policy refresh deferred; preserving the running tunnel."
    refresh_host_routes "$CAMPUS_DIRECT_DOMAINS" "$CAMPUS_DNS_IP" "$CAMPUS_ROUTES_FILE" ||
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
    # Client addresses come from LAN_SUBNET, which is a /24 (e.g. "192.168.8.").
    LAN_PREFIX="${LAN_SUBNET%/*}"
    LAN_PREFIX="${LAN_PREFIX%.*}."
    for PORT in $GAME_SESSION_PORTS; do
        ADDRESSES="$(conntrack -L 2>/dev/null |
            awk -v port="$PORT" -v lan="src=$LAN_PREFIX" '
                index($0, lan) && $0 ~ ("dport=" port "([[:space:]]|$)") {
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
            # shellcheck disable=SC2094 # route_listed_elsewhere skips this file; nothing writes it here.
            while IFS= read -r ROUTE; do
                [ -n "$ROUTE" ] || continue
                grep -Fqx "$ROUTE" "$TMP_ROUTES" 2>/dev/null && continue
                route_listed_elsewhere "$ROUTE" "$GAME_SESSION_ROUTES_FILE" ||
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
    iptables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || return 1
    iptables -t mangle -C FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV4_MSS" 2>/dev/null || return 1
    ip6tables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || return 1
    ip6tables -t mangle -C FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV6_MSS" 2>/dev/null || return 1
    # FORWARD's policy is DROP: LAN<->tun0 traffic exists only through these.
    iptables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || return 1
    iptables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || return 1
    ip6tables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || return 1
    ip6tables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || return 1
}

ensure_nat_and_mss_rules() {
    iptables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o "$TUN_IF" -j MASQUERADE
    ip6tables -t nat -C POSTROUTING -o "$TUN_IF" -j MASQUERADE 2>/dev/null || ip6tables -t nat -I POSTROUTING -o "$TUN_IF" -j MASQUERADE
    iptables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV4_MSS" 2>/dev/null || iptables -t mangle -I FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV4_MSS"
    ip6tables -t mangle -C FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -I FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    ip6tables -t mangle -C FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV6_MSS" 2>/dev/null || ip6tables -t mangle -I FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV6_MSS" 2>/dev/null
    iptables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
    iptables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -C FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT 2>/dev/null || ip6tables -I FORWARD -i "$LAN_IF" -o "$TUN_IF" -j ACCEPT
    ip6tables -C FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -I FORWARD -i "$TUN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

# fw3 filters input only from br-lan and eth0, and INPUT's policy is ACCEPT, so
# new connections arriving on tun0 would reach SSH, the admin UI and DNS. Replies
# are not NEW and still pass. A safeguard, not liveness: never restart WARP for it.
ensure_tunnel_input_drop() {
    for TOOL in iptables ip6tables; do
        "$TOOL" -C INPUT -i "$TUN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null && continue
        if "$TOOL" -I INPUT -i "$TUN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null; then
            log "Added the missing $TOOL rule dropping new inbound connections on $TUN_IF."
        else
            log "WARNING: could not add the $TOOL rule dropping new inbound connections on $TUN_IF."
        fi
    done
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
    TUNNEL_FAILURE_REASON="NAT, MSS or LAN forwarding rule missing"
    if ! nat_rules_ok; then
        ensure_nat_and_mss_rules
        nat_rules_ok || return 1
        log "Reinstalled missing tunnel NAT, MSS or LAN forwarding rules in place."
    fi
    TUNNEL_FAILURE_REASON="both tunnel IPv4 HTTP probes failed"
    tunnel_internet_v4_ok || return 1
    TUNNEL_FAILURE_REASON=""
}

# A lower-metric default (a reset WAN metric, an interrupted game mode) sends
# LAN traffic around WARP while tun0-bound probes still pass. Restarting WARP
# cannot fix that, so report it instead of acting on it.
warn_if_tunnel_not_preferred() {
    ROUTE_V4="$(ip -4 route get "$ROUTE_PROBE_V4" 2>&1 || true)"
    ROUTE_V6="$(ip -6 route get "$ROUTE_PROBE_V6" 2>&1 || true)"
    case "$ROUTE_V4" in
        *" dev $TUN_IF "*)
            case "$ROUTE_V6" in *" dev $TUN_IF "*) return 0 ;; esac ;;
    esac
    log "WARNING: public traffic does not prefer $TUN_IF (IPv4: $(printf '%s' "$ROUTE_V4" | tr '\n' ' '); IPv6: $(printf '%s' "$ROUTE_V6" | tr '\n' ' '))."
    collect_diagnostics_once route-preference
}

# A reachable but slow tunnel (the 08-07/08-09 failure class) passes every
# probe. Restarting on latency caused false restarts, so only report it.
warn_if_tunnel_slow() {
    if ! awk -v t="${TUNNEL_PROBE_TIME:-0}" -v limit="$TUNNEL_SLOW_SECONDS" 'BEGIN { exit !(t + 0 > limit + 0) }'; then
        [ ! -f "$TUNNEL_SLOW_FILE" ] || rm -f "$TUNNEL_SLOW_FILE"
        return 0
    fi
    SLOW_CHECKS="$(cat "$TUNNEL_SLOW_FILE" 2>/dev/null || echo 0)"
    case "$SLOW_CHECKS" in
        ''|*[!0-9]*) SLOW_CHECKS=0 ;;
    esac
    SLOW_CHECKS=$((SLOW_CHECKS + 1))
    printf '%s\n' "$SLOW_CHECKS" 2>/dev/null > "$TUNNEL_SLOW_FILE" || true
    [ "$SLOW_CHECKS" -ge "$TUNNEL_SLOW_CHECKS" ] || return 0
    log "WARNING: the tunnel probe took over ${TUNNEL_SLOW_SECONDS}s on $SLOW_CHECKS consecutive checks (latest ${TUNNEL_PROBE_TIME}s); not restarting."
    collect_diagnostics_once tunnel-slow
}

tunnel_healthy_confirmed() {
    tunnel_healthy && return 0
    # A missing process/interface cannot recover on its own. A live client's
    # reconnect or brief packet loss deserves a second observation. The same
    # check runs before and after a restart, so the message names neither.
    if ! tunnel_process_ok || ! ip link show dev "$TUN_IF" >/dev/null 2>&1; then
        log "Tunnel check failed: $TUNNEL_FAILURE_REASON."
        return 1
    fi
    log "Tunnel check failed: $TUNNEL_FAILURE_REASON. Re-checking in ${TUNNEL_CONFIRM_DELAY}s."
    sleep "$TUNNEL_CONFIRM_DELAY"
    tunnel_healthy
}

# --- Main health check pipeline ---

# Repair Google policy separately; failure must never restart a working WARP.
sh "$DIR/google_wan_policy.sh" >> "$LOG_FILE" 2>&1 ||
    log "Google WAN policy deferred until the WAN is available."

if [ "${ROUTER_SCRIPT_TRIGGER:-}" = firewall ]; then
    log "Starting health check: the firewall was rebuilt."
else
    log "Starting health check."
fi

# After a reboot the clock can be months behind until NTP syncs (86 days was
# seen), which breaks lock ageing and TLS. The log was just written, so its
# mtime is the current clock; this script cannot be newer than now.
if [ "$0" -nt "$LOG_FILE" ]; then
    log "WARNING: the clock reads $(date '+%Y-%m-%d %H:%M:%S'), earlier than this script's modification time. Lock ageing and TLS checks are unreliable until NTP syncs."
fi

maintain_persistent_storage

# The radios are not needed for WAN, portal or WARP recovery, which wired
# clients and the router itself rely on, so a Wi-Fi failure never ends the run.
if wifi_config_ok && wifi_runtime_ok; then
    clear_retry "$WIFI_REPAIR_RETRY_FILE"
elif retry_deferred "$WIFI_REPAIR_RETRY_FILE"; then
    log "Wi-Fi remains degraded; repair cooldown is active. Continuing WAN and tunnel recovery."
else
    if ! wifi_config_ok; then
        log "Wi-Fi stability configuration drift detected. Reapplying configure_wifi.sh."
        sh "$DIR/configure_wifi.sh" >> "$LOG_FILE" 2>&1 || log "configure_wifi.sh failed."
    fi
    if wifi_config_ok && ! wifi_runtime_ok; then
        log "Wi-Fi runtime is down despite valid configuration. Reloading radios."
        wifi reload >> "$LOG_FILE" 2>&1 || true
        sleep 5
    fi
    if wifi_config_ok && wifi_runtime_ok; then
        clear_retry "$WIFI_REPAIR_RETRY_FILE"
    else
        log "Wi-Fi remains degraded after repair. Capturing evidence once and continuing WAN and tunnel recovery."
        collect_diagnostics_once wifi
        defer_retry "$WIFI_REPAIR_RETRY_FILE" "$STAGE_REPAIR_COOLDOWN"
    fi
fi

# Configuration drift (a missing forward, pin or Google ipset entry) does not
# stop dnsmasq answering, so it is repaired without ending the run.
if dns_config_ok; then
    clear_retry "$DNS_CONFIG_RETRY_FILE"
elif retry_deferred "$DNS_CONFIG_RETRY_FILE"; then
    log "DNS configuration remains degraded; repair cooldown is active."
else
    log "DNS configuration drift detected. Reapplying configure_dns.sh."
    sh "$DIR/configure_dns.sh" >> "$LOG_FILE" 2>&1 || log "configure_dns.sh failed."
    if dns_config_ok; then
        clear_retry "$DNS_CONFIG_RETRY_FILE"
    else
        log "DNS configuration remains invalid after repair. Capturing evidence once and continuing."
        collect_diagnostics_once dns-config
        defer_retry "$DNS_CONFIG_RETRY_FILE" "$STAGE_REPAIR_COOLDOWN"
    fi
fi

# Probe-driven actions (portal logout, WARP restart) are unsafe without a
# working resolver, so a dead resolver still ends the run.
if dns_runtime_ok; then
    clear_retry "$DNS_RUNTIME_RETRY_FILE"
elif retry_deferred "$DNS_RUNTIME_RETRY_FILE"; then
    log "DNS runtime remains unhealthy; repair cooldown is active. Skipping probe-driven recovery."
    exit 1
else
    log "dnsmasq is not running or not answering locally. Reapplying DNS configuration."
    sh "$DIR/configure_dns.sh" >> "$LOG_FILE" 2>&1 || log "configure_dns.sh failed during runtime recovery."
    if ! dns_runtime_ok; then
        log "DNS runtime remains unhealthy after repair. Collecting diagnostics."
        collect_diagnostics_once dns-runtime
        defer_retry "$DNS_RUNTIME_RETRY_FILE" "$STAGE_REPAIR_COOLDOWN"
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
        collect_diagnostics_once lan-ipv6
        defer_lan_ipv6_retry
    fi
fi

if ! wan_ipv4_ok || ! wan_link_ok; then
    log "WAN IPv4 lease or Ethernet carrier is missing."
    recover_wan
fi

if ! wan_ipv4_ok || ! wan_link_ok; then
    log "WAN IPv4 lease or carrier is still missing after recovery. Collecting diagnostics."
    collect_diagnostics_once wan-lease
    exit 1
fi

if ! campus_core_route_ok; then
    log "Campus DNS route is not using $WAN_IF."
    if repair_campus_routes && campus_core_route_ok; then
        log "Reinstalled campus routes on $WAN_IF without cycling the WAN."
    else
        recover_wan
    fi
fi

if ! campus_core_route_ok; then
    log "Campus DNS route is still incorrect after WAN recovery. Collecting diagnostics."
    collect_diagnostics_once campus-route
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
        collect_diagnostics_once internet-down
        exit 1
    fi
    log "Internet recovered after tunnel teardown."
fi

if ! runtime_resources_ok; then
    log "Runtime storage pressure detected: /tmp is at or above ${TMP_MAX_USED_PERCENT}% usage. Falling back to direct WAN."
    collect_diagnostics_once tmp-pressure
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    defer_tunnel_retry
    exit 1
fi

# Publish fresh Blinkit IPv4 answers only after their WAN routes exist.
sh "$DIR/refresh_blinkit_dns.sh" >> "$LOG_FILE" 2>&1 ||
    log "Blinkit DNS refresh deferred; preserving last known records."

# Before the game-mode exit: tun0 stays up in game mode, and fw3 reloads drop it.
ensure_tunnel_input_drop

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
    warn_if_tunnel_not_preferred
    warn_if_tunnel_slow
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

if ! tunnel_healthy_confirmed; then
    log "Tunnel is still unhealthy after restart. Collecting diagnostics and enabling direct WAN fallback."
    collect_diagnostics_once tunnel-restart
    sh "$DIR/stop_tunnel.sh" >> "$LOG_FILE" 2>&1 || true
    defer_tunnel_retry
    exit 1
fi

rm -f "$TUNNEL_RETRY_FILE"
refresh_optional_routes
warn_if_tunnel_not_preferred
warn_if_tunnel_slow
log "Health check passed."

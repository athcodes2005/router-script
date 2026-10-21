#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

. "$SCRIPT_DIR/paths.sh"

LOG_FILE="$(prepare_log_file login)"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
else
    log "Error: .env file not found in $SCRIPT_DIR"
    exit 1
fi

: "${USER:?USER must be set in .env}"
: "${PASS:?PASS must be set in .env}"

WAN_IF="${WAN_IF:-eth0}"
PORTAL_BASE_URL="${PORTAL_BASE_URL:-https://internet.iitb.ac.in}"
INTERACTIVE_LOGIN_MARKER="${INTERACTIVE_LOGIN_MARKER:-/tmp/router-script-interactive-login-required}"
INTERNET_PROBE_URLS="${INTERNET_PROBE_URLS:-https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204}"
INTERNET_RECHECK_ATTEMPTS="${INTERNET_RECHECK_ATTEMPTS:-3}"
INTERNET_RECHECK_DELAY="${INTERNET_RECHECK_DELAY:-2}"
INTERNET_PROBE_CONNECT_TIMEOUT="${INTERNET_PROBE_CONNECT_TIMEOUT:-2}"
INTERNET_PROBE_MAX_TIME="${INTERNET_PROBE_MAX_TIME:-4}"
INITIAL_LOGIN_SETTLE_DELAY="${INITIAL_LOGIN_SETTLE_DELAY:-3}"
STALE_SESSION_LOGOUT_DELAY="${STALE_SESSION_LOGOUT_DELAY:-1}"
FRESH_LOGIN_SETTLE_DELAY="${FRESH_LOGIN_SETTLE_DELAY:-3}"

# Pinned IPs for captive-portal domains.  These guarantee curl can reach the
# OAuth chain even if campus DNS is completely dead and dnsmasq has not yet
# loaded the address records.  Kept in sync with configure_dns.sh.
PORTAL_IP="${PORTAL_IP:-10.201.250.201}"
SSO_IP="${SSO_IP:-10.200.1.100}"
RESOLVE_OPTS="--resolve internet.iitb.ac.in:443:${PORTAL_IP} --resolve sso.iitb.ac.in:443:${SSO_IP}"

check_internet() {
    for URL in $INTERNET_PROBE_URLS; do
        CODE="$(curl -4 -sS \
            --interface "$WAN_IF" \
            --connect-timeout "$INTERNET_PROBE_CONNECT_TIMEOUT" \
            --max-time "$INTERNET_PROBE_MAX_TIME" \
            -o /dev/null \
            -w '%{http_code}' \
            "$URL" 2>/dev/null || true)"
        [ "$CODE" = "204" ] && return 0
    done
    return 1
}

wait_for_internet() {
    ATTEMPT=1
    while [ "$ATTEMPT" -le "$INTERNET_RECHECK_ATTEMPTS" ]; do
        check_internet && return 0
        [ "$ATTEMPT" -lt "$INTERNET_RECHECK_ATTEMPTS" ] && sleep "$INTERNET_RECHECK_DELAY"
        ATTEMPT=$((ATTEMPT + 1))
    done
    return 1
}

safe_request_summary() {
    # OAuth callback query strings can contain short-lived authorization codes.
    # Keep status and endpoint path, but never persist queries or fragments.
    printf '%s' "$1" | sed 's/[?#].*$/?[redacted]/'
}

logout_portal() {
    log "Attempting to logout from captive portal to clear hung session."
    WAN_IP="$(ip -4 addr show dev "$WAN_IF" | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')"
    case "$WAN_IP" in
        *.*.*.*) ;;
        *)
            log "Logout skipped: $WAN_IF has no usable IPv4 address."
            return 1
            ;;
    esac
    RESULT="$(curl -4 -sS \
        --interface "$WAN_IF" \
        $RESOLVE_OPTS \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        --data-urlencode 'button=Logout' \
        --data-urlencode "ip=$WAN_IP" \
        --data-urlencode "etype=${PORTAL_ETYPE:-ug}" \
        -o /dev/null \
        -w 'HTTP %{http_code} final=%{url_effective}' \
        "$PORTAL_BASE_URL/logout.php" 2>&1)" || true
    log "Logout request: $(safe_request_summary "$RESULT")"
    log_tls_clock_hint "$RESULT"
}

# curl reads the credentials from stdin as a config line, so the token never
# appears in its command line (/proc/<pid>/cmdline is world-readable).
# Backslashes and double quotes are escaped for curl's quoted-string syntax.
curl_credentials() {
    printf 'user = "%s:%s"\n' \
        "$(printf '%s' "$USER" | sed 's/[\\"]/\\&/g')" \
        "$(printf '%s' "$PASS" | sed 's/[\\"]/\\&/g')"
}

# A clock months behind (after a reboot, before NTP syncs) makes the portal's
# valid certificate look "not yet valid"; name the likely cause.
log_tls_clock_hint() {
    case "$1" in
        *"curl: (60)"*|*"not yet valid"*|*"certificate has expired"*)
            log "TLS verification failed. Check the router clock first: it reads $(date '+%Y-%m-%d %H:%M:%S'), and NTP may not have synced since boot."
            ;;
    esac
}

token_login() {
    TOKEN_LOGIN_STATE="unknown"
    RESULT="$(curl_credentials | curl -4 -sS \
        --interface "$WAN_IF" \
        $RESOLVE_OPTS \
        --connect-timeout 10 \
        --max-time 30 \
        --location-trusted \
        --proto '=https' \
        --proto-redir '=https' \
        --max-redirs 5 \
        -K - \
        -o /dev/null \
        -w 'HTTP %{http_code} final=%{url_effective}' \
        "$PORTAL_BASE_URL/login.php" 2>&1)" || true
    log "Access-token login request: $(safe_request_summary "$RESULT")"
    log_tls_clock_hint "$RESULT"
    case "$RESULT" in
        *"/logout.php"*) TOKEN_LOGIN_STATE="stale-session" ;;
        *"/login.php"*) TOKEN_LOGIN_STATE="login-response" ;;
    esac
}

recover_stale_session() {
    logout_portal
    sleep "$STALE_SESSION_LOGOUT_DELAY"

    log "Attempting a fresh login after logout."
    token_login
    sleep "$FRESH_LOGIN_SETTLE_DELAY"
    wait_for_internet
}

require_interactive_login() {
    printf '%s\n' "$PORTAL_BASE_URL/login.php" > "$INTERACTIVE_LOGIN_MARKER"
    log "Access-token recovery failed; interactive IITB SSO login is required."
}

if ! check_internet; then
    log "No internet connection. Attempting captive portal authentication on $WAN_IF."

    # First login attempt
    token_login

    # A token request ending on logout.php has consistently meant that IITB
    # retained a stale authenticated record while public forwarding was down.
    # Waiting for public probes cannot repair that state, so clear it at once.
    if [ "$TOKEN_LOGIN_STATE" = "stale-session" ]; then
        log "Token login reached logout.php while internet is down; clearing stale portal session immediately."
        if recover_stale_session; then
            rm -f "$INTERACTIVE_LOGIN_MARKER"
            log "Successful recovery: Internet is active after immediate stale-session re-login."
            exit 0
        fi
        require_interactive_login
        exit 2
    fi

    # Wait for the backend to process the login
    sleep "$INITIAL_LOGIN_SETTLE_DELAY"
    
    # Check if internet came back. If not, the session is likely hung.
    if ! wait_for_internet; then
        log "Internet remains down after login. Captive portal session might be hung."
        if recover_stale_session; then
            rm -f "$INTERACTIVE_LOGIN_MARKER"
            log "Successful recovery: Internet is active after re-login."
        else
            require_interactive_login
            exit 2
        fi
    else
        rm -f "$INTERACTIVE_LOGIN_MARKER"
        log "First login successful. Internet is active."
    fi
else
    rm -f "$INTERACTIVE_LOGIN_MARKER"
    log "Internet connection is active."
fi

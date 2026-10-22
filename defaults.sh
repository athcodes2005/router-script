#!/bin/sh
# Defaults that more than one script uses, kept in one place: a list copied
# into several scripts drifts, and four past incidents were a name missing
# from one copy. Source it after .env, so that .env's values win.

# Interfaces and addresses
WAN_IF="${WAN_IF:-eth0}"
WAN_UCI_IFACE="${WAN_UCI_IFACE:-wan}"
LAN_IF="${LAN_IF:-br-lan}"
LAN_SUBNET="${LAN_SUBNET:-192.168.8.0/24}"
LAN_IP6IFACEID="${LAN_IP6IFACEID:-::1}"
LAN_RA_DEFAULT="${LAN_RA_DEFAULT:-2}"
TUN_IF="${TUN_IF:-tun0}"
TUN_IPV4_MSS="${TUN_IPV4_MSS:-1240}"
TUN_IPV6_MSS="${TUN_IPV6_MSS:-1220}"

# Campus network, portal and DNS
CAMPUS_NETS="${CAMPUS_NETS:-10.0.0.0/8 103.21.124.0/22}"
CAMPUS_DNS_IP="${CAMPUS_DNS_IP:-10.200.1.11}"
CAMPUS_DOMAINS="${CAMPUS_DOMAINS:-internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
PORTAL_IP="${PORTAL_IP:-10.201.250.201}"
SSO_IP="${SSO_IP:-10.200.1.100}"
DNSCRYPT_TOML="${DNSCRYPT_TOML:-/etc/dnscrypt-proxy2/dnscrypt-proxy.toml}"
INTERNET_PROBE_URLS="${INTERNET_PROBE_URLS:-https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204}"
INTERACTIVE_LOGIN_MARKER="${INTERACTIVE_LOGIN_MARKER:-/tmp/router-script-interactive-login-required}"

# Hosts kept off WARP, and the files recording their routes. tunnel.sh, the
# health check, the Blinkit refresher and stop_tunnel.sh must all agree.
CAMPUS_DIRECT_DOMAINS="${CAMPUS_DIRECT_DOMAINS:-www.cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in}"
# Selected public services that reject WARP/shared-proxy egress. These are
# intentionally exact hostnames observed from the affected app; broad CDN
# ranges would accidentally bypass WARP for unrelated sites.
DIRECT_PUBLIC_DOMAINS="${DIRECT_PUBLIC_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com o1069899.ingest.us.sentry.io gemini.google.com game.clashroyaleapp.com id.supercell.com init.mkt.supercell.com o315582.ingest.sentry.io clashroyale.com www.clashroyale.com}"
BLINKIT_IPV4_DOMAINS="${BLINKIT_IPV4_DOMAINS:-api3.blinkit.com jumbo.blinkit.com api2.grofers.com}"
BLINKIT_HOSTS_DIR="${BLINKIT_HOSTS_DIR:-/etc/router-script/blinkit-hosts}"
CAMPUS_ROUTES_FILE="${CAMPUS_ROUTES_FILE:-/tmp/router-script-campus-host-routes}"
DIRECT_PUBLIC_ROUTES_FILE="${DIRECT_PUBLIC_ROUTES_FILE:-/tmp/router-script-direct-public-host-routes}"
GAME_SESSION_ROUTES_FILE="${GAME_SESSION_ROUTES_FILE:-/tmp/router-script-game-session-host-routes}"

# Game-session policy routing, and game mode
GAME_SESSION_PORTS="${GAME_SESSION_PORTS:-9339}"
GAME_POLICY_TABLE="${GAME_POLICY_TABLE:-101}"
GAME_POLICY_PRIORITY="${GAME_POLICY_PRIORITY:-700}"
GAME_POLICY_MARK="${GAME_POLICY_MARK:-0x40000}"
GAME_POLICY_MASK="${GAME_POLICY_MASK:-0xf0000}"
GAME_MODE_MARKER="${GAME_MODE_MARKER:-/tmp/router-script-game-mode}"

# WARP
WARP_ENDPOINTS="${WARP_ENDPOINTS:-162.159.198.1 162.159.192.1}"
WARP_READY_FILE="${WARP_READY_FILE:-/tmp/router-script-warp-ready}"
WARP_CLIENT_TABLE="${WARP_CLIENT_TABLE:-100}"

# Wi-Fi
WIFI_COUNTRY="${WIFI_COUNTRY:-IN}"
WIFI_2G_DEVICE="${WIFI_2G_DEVICE:-mt798111}"
WIFI_5G_DEVICE="${WIFI_5G_DEVICE:-mt798112}"
WIFI_2G_HTMODE="${WIFI_2G_HTMODE:-HE20}"
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE80}"

# Diagnostics
MAX_DIAGNOSTICS="${MAX_DIAGNOSTICS:-24}"

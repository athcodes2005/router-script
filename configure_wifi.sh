#!/bin/sh

# Apply a conservative Wi-Fi profile for a dense campus environment.
# Narrower channels trade unused peak PHY rate for lower interference and
# better compatibility/latency, which is preferable for games and calls.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file wifi)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi
. "$DIR/defaults.sh"

WIFI_APPLY="${WIFI_APPLY:-1}"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

for DEVICE in "$WIFI_2G_DEVICE" "$WIFI_5G_DEVICE"; do
    if [ "$(uci -q get "wireless.$DEVICE" 2>/dev/null || true)" != "wifi-device" ]; then
        log "ERROR: wireless.$DEVICE is not a configured Wi-Fi device."
        exit 1
    fi
done

CHANGED=0

set_option() {
    SECTION="$1"
    OPTION="$2"
    VALUE="$3"

    if [ "$(uci -q get "wireless.$SECTION.$OPTION" 2>/dev/null || true)" != "$VALUE" ]; then
        uci set "wireless.$SECTION.$OPTION=$VALUE"
        CHANGED=1
    fi
}

set_option "$WIFI_2G_DEVICE" country "$WIFI_COUNTRY"
set_option "$WIFI_5G_DEVICE" country "$WIFI_COUNTRY"
set_option "$WIFI_2G_DEVICE" htmode "$WIFI_2G_HTMODE"
set_option "$WIFI_5G_DEVICE" htmode "$WIFI_5G_HTMODE"

if [ "$CHANGED" -eq 0 ]; then
    log "Wi-Fi stability profile already active."
    exit 0
fi

uci commit wireless
log "Applied Wi-Fi profile: country=$WIFI_COUNTRY, 2.4GHz=$WIFI_2G_HTMODE, 5GHz=$WIFI_5G_HTMODE."

if [ "$WIFI_APPLY" -eq 1 ] 2>/dev/null; then
    log "Reloading Wi-Fi to activate the profile."
    wifi reload
fi

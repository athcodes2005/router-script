#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

. "$DIR/paths.sh"

LOG_FILE="$(prepare_log_file ipv6)"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

LAN_IP6ASSIGN="${LAN_IP6ASSIGN:-60}"
LAN_IP6IFACEID="${LAN_IP6IFACEID:-::1}"
LAN_RA_DEFAULT="${LAN_RA_DEFAULT:-2}"
LAN_IF="${LAN_IF:-br-lan}"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# Some vendor netifd builds expose a ULA prefix assignment in ifstatus while
# leaving its local-address empty after reboot. Give br-lan an explicit address
# from the router's ULA /48 so LAN IPv6 does not depend on that runtime
# delegation path. An environment override remains available for unusual ULA
# layouts.
if [ -z "${LAN_IP6ADDR:-}" ]; then
    ULA_PREFIX="$(uci -q get network.globals.ula_prefix 2>/dev/null || true)"
    case "$ULA_PREFIX" in
        *::/48) LAN_IP6ADDR="${ULA_PREFIX%::/48}::1/64" ;;
        *)
            log "Cannot derive LAN_IP6ADDR from network.globals.ula_prefix=$ULA_PREFIX"
            exit 1
            ;;
    esac
fi

log "Starting LAN IPv6 configuration"
log "This may briefly interrupt Wi-Fi/LAN connectivity while lan reloads."

# This script runs before tunnel.sh during recovery. Do not rely on the tunnel
# launcher to enable IPv6 first, or the health pipeline can deadlock before it
# ever reaches WARP startup.
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >> "$LOG_FILE" 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >> "$LOG_FILE" 2>&1
if [ -e "/proc/sys/net/ipv6/conf/$LAN_IF/disable_ipv6" ]; then
    sysctl -w "net.ipv6.conf.$LAN_IF.disable_ipv6=0" >> "$LOG_FILE" 2>&1
fi

# Never filtered, game mode included: this dnsmasq ignores the option anyway.
uci set dhcp.@dnsmasq[0].filter_aaaa='0'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_default="$LAN_RA_DEFAULT"
uci set network.lan.ip6assign="$LAN_IP6ASSIGN"
uci set network.lan.ip6ifaceid="$LAN_IP6IFACEID"
uci set network.lan.ip6addr="$LAN_IP6ADDR"
uci commit dhcp
uci commit network

log "Restarting dnsmasq"
/etc/init.d/dnsmasq restart >> "$LOG_FILE" 2>&1

log "Enabling and restarting odhcpd"
/etc/init.d/odhcpd enable >> "$LOG_FILE" 2>&1
/etc/init.d/odhcpd restart >> "$LOG_FILE" 2>&1

log "Reloading lan interface"
ifup lan >> "$LOG_FILE" 2>&1
sleep 5

log "Current LAN IPv6 status"
ifstatus lan >> "$LOG_FILE" 2>&1
ip -6 addr show dev br-lan >> "$LOG_FILE" 2>&1

log "Verification summary"
log "Configured LAN address $LAN_IP6ADDR and dhcp.lan.ra_default=$LAN_RA_DEFAULT for the ULA+NAT66 setup."
ifstatus lan | sed -n '1,40p'
echo "---"
ip -6 addr show dev br-lan | sed -n '1,20p'

#!/bin/sh
# Register firewall_hook.sh as an fw3 script include, so a health check runs as
# soon as the firewall is rebuilt. Safe to run again. To remove it:
#   uci delete firewall.router_script && uci commit firewall

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"

uci -q delete firewall.router_script || true
uci set firewall.router_script=include
uci set firewall.router_script.type=script
uci set firewall.router_script.path="$DIR/firewall_hook.sh"
uci set firewall.router_script.reload=1
uci commit firewall

echo "Registered fw3 include firewall.router_script: $DIR/firewall_hook.sh"

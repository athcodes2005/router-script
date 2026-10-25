#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"

chmod +x "$DIR"/*.sh "$DIR/usque-rs" 2>/dev/null || true

SYSUPGRADE_CONF="${SYSUPGRADE_CONF:-/etc/sysupgrade.conf}"
if [ -f "$SYSUPGRADE_CONF" ] || [ -d "$(dirname "$SYSUPGRADE_CONF")" ]; then
    for KEEP_PATH in "$DIR/" /etc/router-script/; do
        if ! grep -Fqx "$KEEP_PATH" "$SYSUPGRADE_CONF" 2>/dev/null; then
            printf '%s\n' "$KEEP_PATH" >> "$SYSUPGRADE_CONF"
        fi
    done
fi

cd "$DIR"
./configure_wifi.sh
./configure_dns.sh
./configure_lan_ipv6.sh
./install_cron_pipeline.sh
./install_firewall_hook.sh
./ensure_network.sh

echo "Bootstrap complete."

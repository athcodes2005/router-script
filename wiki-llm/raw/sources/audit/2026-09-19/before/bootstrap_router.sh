#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"

chmod +x "$DIR"/*.sh "$DIR/usque-rs" 2>/dev/null || true

cd "$DIR"
./configure_wifi.sh
./configure_dns.sh
./configure_lan_ipv6.sh
./install_cron_pipeline.sh
./ensure_network.sh

echo "Bootstrap complete."

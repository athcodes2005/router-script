#!/bin/sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_CRON="$(mktemp)"
START_MARKER="# BEGIN ROUTER-SCRIPT PIPELINE"
END_MARKER="# END ROUTER-SCRIPT PIPELINE"

cleanup() {
    rm -f "$TMP_CRON"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

(crontab -l 2>/dev/null || true) | sed "/$START_MARKER/,/$END_MARKER/d" > "$TMP_CRON"

cat >> "$TMP_CRON" <<EOF
$START_MARKER
*/1 * * * * cd "$DIR" && ./ensure_network.sh >/dev/null 2>&1
*/1 * * * * sleep 30; cd "$DIR" && ./ensure_network.sh >/dev/null 2>&1
7,22,37,52 * * * * cd "$DIR" && ./update_from_git.sh >/dev/null 2>&1
17 */6 * * * cd "$DIR" && ./collect_diagnostics.sh >/dev/null 2>&1
47 */6 * * * cd "$DIR" && ./rotate_logs.sh >/dev/null 2>&1
$END_MARKER
EOF

crontab "$TMP_CRON"

if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi

echo "Installed router-script cron pipeline:"
crontab -l | sed -n "/$START_MARKER/,/$END_MARKER/p"

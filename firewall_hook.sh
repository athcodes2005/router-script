#!/bin/sh
# fw3 script include, registered by install_firewall_hook.sh. fw3 sources this
# file with sh after it rebuilds the firewall: on start and restart (which first
# flush every chain, so every rule router-script added is gone) and on reload
# (which keeps them, and also follows an interface coming up). A health check
# restores what is missing now instead of up to 30 s later from cron. It runs
# detached and after a delay: fw3 holds its lock until its includes return, and
# the health check can restart services whose hotplug hooks run fw3 again.
# Without a WARP client there is nothing of the tunnel's to restore.
if pidof usque-rs >/dev/null 2>&1; then
    ROUTER_SCRIPT_HOOK="$(uci -q get firewall.router_script.path 2>/dev/null)"
    case "$ROUTER_SCRIPT_HOOK" in
        /*/firewall_hook.sh)
            (
                sleep 2
                cd "${ROUTER_SCRIPT_HOOK%/*}" || exit 0
                ROUTER_SCRIPT_TRIGGER=firewall
                export ROUTER_SCRIPT_TRIGGER
                exec ./ensure_network.sh
            ) </dev/null >/dev/null 2>&1 &
            ;;
    esac
fi

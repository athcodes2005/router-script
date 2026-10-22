#!/bin/sh
# The maintenance lock, held by whatever changes routing or firewall state:
# ensure_network.sh, game_mode.sh, rotate_tunnel_ip.sh and the promotion step of
# sync_to_router.sh. Source it with DIR set and log() defined.
#
# mkdir takes the lock atomically. The owner file then records
# "PID START SINCE NAME": the process start time in clock ticks since boot
# (field 22 of /proc/PID/stat), the uptime in seconds when the lock was taken,
# and the script. The lock is taken over when
#   - its owner is gone: the PID is dead, or now belongs to another process
#     (PIDs are reused within hours here, and the lock directory survives a
#     reboot);
#   - its owner has held it for MAINTENANCE_LOCK_MAX_HOLD seconds, so a hung
#     rotation cannot stop recovery for good. Uptime, unlike the clock, never
#     jumps, so no clock change can make a live owner look old;
#   - it records no owner (taken by hand, by an older script, or by one that
#     died right after mkdir) and its directory is older than
#     MAINTENANCE_LOCK_OWNERLESS_AGE by the clock, or dated in the future,
#     which means the clock went back, as after a reboot before NTP syncs.
# A second directory serializes takeovers: two contenders that both find the
# lock stale cannot both end up holding it.

MAINTENANCE_LOCK_DIR="${MAINTENANCE_LOCK_DIR:-$DIR/.ensure_network.lock}"
MAINTENANCE_LOCK_MAX_HOLD="${MAINTENANCE_LOCK_MAX_HOLD:-600}"
MAINTENANCE_LOCK_OWNERLESS_AGE="${MAINTENANCE_LOCK_OWNERLESS_AGE:-${LOCK_MAX_AGE:-180}}"
MAINTENANCE_LOCK_NAME="${MAINTENANCE_LOCK_NAME:-${0##*/}}"
MAINTENANCE_LOCK_HELD=0
MAINTENANCE_LOCK_BUSY=

lock_count() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# The command name in field 2 is in parentheses and may contain spaces.
lock_process_start() {
    awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null || :
}

lock_uptime() {
    awk '{ printf "%d\n", $1 }' "/proc/uptime" 2>/dev/null || echo 0
}

# Clock age of a directory; a directory dated in the future counts as old.
lock_dir_older_than() {
    LOCK_NOW="$(date +%s)"
    LOCK_MTIME="$(date -r "$1" +%s 2>/dev/null)" || return 1
    LOCK_AGE=$((LOCK_NOW - LOCK_MTIME))
    [ "$LOCK_AGE" -gt "$2" ] || [ "$LOCK_AGE" -lt -60 ]
}

# Sets LOCK_STALE to why the lock may be taken over, or to nothing while its
# owner may still need it; sets MAINTENANCE_LOCK_BUSY to who holds it.
check_maintenance_lock() {
    LOCK_STALE=
    OWNER_PID=
    OWNER_START=
    OWNER_SINCE=
    OWNER_NAME=
    read -r OWNER_PID OWNER_START OWNER_SINCE OWNER_NAME 2>/dev/null < "$MAINTENANCE_LOCK_DIR/owner" || true
    if ! lock_count "$OWNER_PID" || ! lock_count "$OWNER_START" || ! lock_count "$OWNER_SINCE"; then
        MAINTENANCE_LOCK_BUSY="an unrecorded owner"
        if lock_dir_older_than "$MAINTENANCE_LOCK_DIR" "$MAINTENANCE_LOCK_OWNERLESS_AGE"; then
            if [ "$LOCK_AGE" -lt 0 ]; then
                LOCK_STALE="it records no owner and is dated $((-LOCK_AGE))s in the future"
            else
                LOCK_STALE="it records no owner and is ${LOCK_AGE}s old"
            fi
        fi
        return 0
    fi
    MAINTENANCE_LOCK_BUSY="${OWNER_NAME:-its owner} (PID $OWNER_PID)"
    # Our own PID cannot be a live owner: we are still trying to take the lock.
    if [ "$OWNER_PID" = "$$" ] || ! kill -0 "$OWNER_PID" 2>/dev/null; then
        LOCK_STALE="its owner, $MAINTENANCE_LOCK_BUSY, is gone"
    elif [ "$OWNER_START" != 0 ] && [ "$(lock_process_start "$OWNER_PID")" != "$OWNER_START" ]; then
        LOCK_STALE="its owner, $MAINTENANCE_LOCK_BUSY, is gone; the PID now belongs to another process"
    else
        LOCK_HELD_FOR=$(($(lock_uptime) - OWNER_SINCE))
        if [ "$LOCK_HELD_FOR" -gt "$MAINTENANCE_LOCK_MAX_HOLD" ]; then
            LOCK_STALE="$MAINTENANCE_LOCK_BUSY has held it for ${LOCK_HELD_FOR}s"
        fi
    fi
}

# Returns 0 once the stale lock is removed, so the caller can mkdir again.
take_over_stale_maintenance_lock() {
    LOCK_TAKEOVER_DIR="$MAINTENANCE_LOCK_DIR.takeover"
    if ! mkdir "$LOCK_TAKEOVER_DIR" 2>/dev/null; then
        # A contender that died in the few milliseconds it holds this left it.
        if lock_dir_older_than "$LOCK_TAKEOVER_DIR" 60; then
            rmdir "$LOCK_TAKEOVER_DIR" 2>/dev/null || true
        fi
        return 1
    fi
    LOCK_TAKEN=1
    if [ ! -d "$MAINTENANCE_LOCK_DIR" ]; then
        LOCK_TAKEN=0  # released meanwhile
    else
        # Checked again here: another contender may have taken it over already.
        check_maintenance_lock
        if [ -n "$LOCK_STALE" ]; then
            log "WARNING: taking over the maintenance lock: $LOCK_STALE."
            rm -f "$MAINTENANCE_LOCK_DIR/owner"
            rmdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null && LOCK_TAKEN=0
        fi
    fi
    rmdir "$LOCK_TAKEOVER_DIR" 2>/dev/null || true
    return "$LOCK_TAKEN"
}

# Takes the lock, waiting up to $1 seconds while a live owner holds it.
# Returns 1 if it stays busy; MAINTENANCE_LOCK_BUSY then says who holds it.
acquire_maintenance_lock() {
    LOCK_WAITED=0
    until mkdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null; do
        take_over_stale_maintenance_lock && continue
        [ -n "$MAINTENANCE_LOCK_BUSY" ] || check_maintenance_lock
        [ "$LOCK_WAITED" -lt "$1" ] || return 1
        sleep 1
        LOCK_WAITED=$((LOCK_WAITED + 1))
        MAINTENANCE_LOCK_BUSY=
    done
    LOCK_START="$(lock_process_start "$$")"
    lock_count "$LOCK_START" || LOCK_START=0
    printf '%s %s %s %s\n' "$$" "$LOCK_START" "$(lock_uptime)" "$MAINTENANCE_LOCK_NAME" \
        > "$MAINTENANCE_LOCK_DIR/owner"
    MAINTENANCE_LOCK_HELD=1
    MAINTENANCE_LOCK_BUSY=
}

# Releases the lock if we still own it; after a takeover it is someone else's.
release_maintenance_lock() {
    [ "$MAINTENANCE_LOCK_HELD" -eq 1 ] || return 0
    MAINTENANCE_LOCK_HELD=0
    OWNER_PID=
    read -r OWNER_PID _ 2>/dev/null < "$MAINTENANCE_LOCK_DIR/owner" || true
    [ "$OWNER_PID" = "$$" ] || return 0
    rm -f "$MAINTENANCE_LOCK_DIR/owner"
    rmdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null || true
}

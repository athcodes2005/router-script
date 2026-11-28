# Health checking and recovery

Cron runs `ensure_network.sh` at the start and midpoint of every minute, and
the fw3 include `firewall_hook.sh` runs it right after fw3 rebuilds the firewall
(see [[../flows/boot-and-recovery]]). The maintenance lock (`lock.sh`) records
its owner's PID, start time, uptime and script, so staggered jobs and the other
lock holders cannot overlap. A live owner is never displaced by age; a dead one,
or one whose PID now belongs to another process, is taken over at once, and one
that has held the lock for 600 s of uptime is taken over as hung. Only a lock
with no owner record still ages by the clock (180 s, or at once if it is dated
in the future after a clock reset).

## Check order

1. Warn when the clock reads earlier than the script's own modification time
   (after a reboot, before NTP syncs; this breaks lock ageing and TLS).
2. Bound project logs when overlay storage crosses the warning threshold.
3. Repair Wi-Fi configuration or reload a configured but down radio.
4. Repair DNS configuration (the four upstreams first and in strict order with
   `127.0.0.1#5453` primary, forwards for exactly the listed campus hosts,
   portal/SSO address pins, and the `dnsproxy` configuration that replaced
   `dnscrypt-proxy2`) and the dnsmasq runtime. Then, when `/etc/init.d/dnsproxy`
   exists and `dnsproxy.yaml` names port 5453, restart `dnsproxy` if its process
   is gone (logged; a failed restart only warns; one that keeps dying is
   restarted once per five-minute cooldown, not on every tick). Routers
   without `dnsproxy` are untouched. `dns_runtime_ok` cannot see this failure,
   because its probe name is a local `address=` pin.
5. Repair LAN IPv6 configuration drift.
6. Verify Ethernet carrier and the WAN IPv4 lease before cycling the WAN. An
   interface that is up without carrier (cable out) is logged and never cycled.
   A missing lease cycles the WAN at most once per `WAN_RECOVERY_COOLDOWN`
   (120 s): a cycle restarts DHCP from nothing, and one on every tick could keep
   a slow server's lease from arriving. The campus-route cycle in step 7 shares
   the cooldown.
7. Verify the core campus route separately from optional resolved site routes.
   With a healthy lease, a wrong route is fixed by reinstalling `CAMPUS_NETS`
   via the WAN gateway; the WAN is cycled only if that fails, because a cycle
   obtains a new DHCP address and resets every flow.
8. Once per boot, check the platform assumptions: the tools the scripts need,
   both radio sections, a WAN metric above WARP's 5 (outside game mode) and the
   fw3 include. It logs "Platform check passed." or one WARNING, and changes
   nothing.
9. Verify direct-WAN IPv4 (probing `cp.cloudflare.com` before Google) once on
   healthy ticks. When direct `eth0` probes stall outside game mode, check
   `tunnel_healthy` first: if `tun0` is up and passing traffic, query
   `https://internet.iitb.ac.in/login.php` over `eth0` (using pinned `PORTAL_IP`)
   without following redirects (`portal_session_logged_out`). IITB's stateful
   firewall lets an already-established WARP UDP/QUIC conntrack flow continue
   after the captive portal session expires, while campus DNS (`10.200.1.11`)
   returns `NXDOMAIN` for internal campus domains and `/login.php` redirects to
   `sso.iitb.ac.in`. Only when `/login.php` explicitly redirects to
   `sso.iitb.ac.in` does `ensure_network.sh` run `login.sh` (without stopping
   healthy `tun0`); when `/login.php` redirects to `logout.php` or is
   unreachable, it assumes a direct-WAN TCP 443 proxy stall, skips `login.sh`
   (avoiding `logout.php` and an ~18 s full-LAN blackout), and reuses that
   tunnel health check. Only when both direct `eth0` and `tun0` fail (or in
   game mode) does it confirm direct failure, run `login.sh`
   ([[portal-login]]), tear down WARP if both paths remain down after recovery,
   and clear any stale interactive-login marker upon post-teardown recovery.
10. Every 10 minutes of uptime (on ticks where direct `eth0` answered), compare the clock with the `Date` header of a
    direct probe, and log a WARNING when they differ by more than 120 s
    (`CLOCK_CHECK_INTERVAL`, `CLOCK_SKEW_WARN_SECONDS`). This catches a time
    client that has stopped correcting the clock, which step 1 misses: after a
    reboot the clock restarts from the newest file under `/etc`, usually later
    than this script's mtime.
11. Reject WARP startup when `/tmp` is at or above the configured threshold.
12. Restore the `tun0` rule dropping new inbound connections if a firewall reload
    removed it; never a restart trigger ([[../security/secrets-and-trust]]).
13. Validate process, CONNECT-IP readiness, TUN, default routes, NAT, MSS and
   LAN↔tun0 FORWARD accept rules (missing rules are reinstalled in place and
   logged), and IPv4 HTTP reachability explicitly bound to the tunnel.
14. Confirm live-client failures after three seconds before restarting WARP.
15. Refresh optional host routes independently after a successful health check
    ([[../systems/host-routes]]).
16. Warn (log plus one rate-limited snapshot, no restart) when a lower-metric
    default would carry public IPv4 or IPv6 around `tun0`; a restart cannot fix
    that, and the tunnel-bound probes alone would not notice it.
17. Warn the same way when the tunnel probe took over 1.5 s on three
    consecutive checks (`TUNNEL_SLOW_SECONDS`, `TUNNEL_SLOW_CHECKS`). One fast
    check resets the count.

18. Probe IPv6 through the tunnel. Three failed checks in a row while IPv4 works
    log a warning and take one snapshot (then every twentieth check). It never
    restarts WARP: IPv4 is what the fallback protects.

A tick that found nothing to do is not written to the log, only counted in RAM
and shown on the terminal: its two lines every 30 s were 5,760 flash appends a
day. The log gets "Health check passed, as did N checks ..." once per
`HEALTHY_LOG_INTERVAL` (one hour of uptime; 0 logs every tick). A tick that
logged anything else is written in full, and one that ends without a result
says so.

Every Wi-Fi, DNS, and LAN IPv6 repair is followed by a postcondition check.
A repair that still fails captures diagnostics once and enters a five-minute
cooldown (`STAGE_REPAIR_COOLDOWN`; LAN IPv6 has its own), so radios, dnsmasq
and the LAN are not reloaded every tick. Wi-Fi, DNS configuration and LAN IPv6
failures then continue to WAN, portal and WARP recovery. Only a dead resolver
(DNS runtime) still ends the run, because portal logout and WARP restart
decisions depend on probes that need DNS.

## Fallback behaviour

**Resource pressure.** The default `/tmp` threshold is 90 percent. At or above it, the pipeline takes a
diagnostic snapshot, removes tunnel routing/process state, restores direct WAN,
and writes a retry-after timestamp. This protects the RAM-backed filesystem and
prevents a failing WARP process from intensifying pressure.

**Failed restart.** If `tunnel.sh` itself exits non-zero, the 10-second
post-start wait is skipped. If a single restart does not restore tunnel health
and IPv4 reachability, diagnostics are captured and WARP is stopped; direct IPv4
(`internet_v4_ok`) is then re-checked so a five-minute cooldown is only imposed
when direct WAN is healthy (never when a mid-tick WAN outage caused the tunnel
start to fail). Runs during a genuine WARP cooldown maintain direct IPv4 instead
of restarting every minute. Both a healthy tunnel and a direct-WAN recovery
(clearing `WAN_RECOVERY_RETRY_FILE`, clearing `INTERACTIVE_LOGIN_MARKER`, or
successful portal recovery) clear the cooldown marker immediately so WARP
restarts on the first healthy WAN tick.

## Observation and game mode

Each failure now logs the failing layer. A live process/interface receives a
second health observation after `TUNNEL_CONFIRM_DELAY` (default three seconds);
a missing process/interface triggers immediate recovery. IPv6 HTTP and latency
are diagnostic measurements, not restart triggers (sustained latency only logs a
warning). IPv6 default-route presence remains a structural requirement.

Game mode ends by itself: its marker records the uptime at which it was turned
on, and the first health check after `GAME_MODE_MAX_SECONDS` (8 h; 0 = never)
runs `game_mode.sh off` before taking the lock. Left on, it sent all public
traffic around WARP until the next reboot while every check "passed".

`game_mode.sh on` prefers direct campus WAN. Policy toggles share the maintenance
lock, and disabling game mode preserves the WAN gateway before removing its
preferred route. Game mode hides IPv6 by rejecting LAN→`tun0` IPv6, not through
DNS: `filter_aaaa` stays 0 in every mode ([[../bugs/known-issues]]).

## Verification runs (gate)

`update_from_git.sh`, `fetch_usque_rs.sh` and `sync_to_router.sh` run the check
with `ROUTER_SCRIPT_TRIGGER=gate` to decide whether a change is kept. In a gate
run exit 0 means WARP was tested and works. It waits up to `GATE_LOCK_WAIT`
(60 s) for the lock instead of skipping, and restarts WARP even during the retry
cooldown. A run that cannot test WARP exits 75: the lock stayed busy, game mode
is on, or an interactive login is pending. A cron tick still exits 0 in all of
those cases, which the updaters once read as "verified".

## Operational result

The system prefers full dual-stack WARP, but prioritizes a responsive direct
IPv4 fallback over a configured yet nonfunctional tunnel. See
[[../flows/boot-and-recovery]] for the state flow.

## Sources

- `../../../ensure_network.sh`, `../../../lock.sh`, `../../../firewall_hook.sh`
- `../../../stop_tunnel.sh`
- `../../../collect_diagnostics.sh`
- `../../../login.sh`
- `../../../paths.sh`

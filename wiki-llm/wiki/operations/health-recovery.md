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
4. Repair DNS configuration (the four upstreams first and in strict order,
   forwards for exactly the listed campus hosts, portal/SSO address pins, the
   dnscrypt listen address) and the dnsmasq runtime.
5. Repair LAN IPv6 configuration drift.
6. Verify Ethernet carrier and the WAN IPv4 lease before cycling the WAN.
7. Verify the core campus route separately from optional resolved site routes.
   With a healthy lease, a wrong route is fixed by reinstalling `CAMPUS_NETS`
   via the WAN gateway; the WAN is cycled only if that fails, because a cycle
   obtains a new DHCP address and resets every flow.
8. Once per boot, check the platform assumptions: the tools the scripts need,
   both radio sections, a WAN metric above WARP's 5 (outside game mode) and the
   fw3 include. It logs "Platform check passed." or one WARNING, and changes
   nothing.
9. Verify direct-WAN IPv4 and run portal login recovery when needed
   ([[portal-login]]).
10. Reject WARP startup when `/tmp` is at or above the configured threshold.
11. Restore the `tun0` rule dropping new inbound connections if a firewall reload
    removed it; never a restart trigger ([[../security/secrets-and-trust]]).
12. Validate process, CONNECT-IP readiness, TUN, default routes, NAT, MSS and
   LAN↔tun0 FORWARD accept rules (missing rules are reinstalled in place and
   logged), and IPv4 HTTP reachability explicitly bound to the tunnel.
13. Confirm live-client failures after three seconds before restarting WARP.
14. Refresh optional host routes independently after a successful health check
    ([[../systems/host-routes]]).
15. Warn (log plus one rate-limited snapshot, no restart) when a lower-metric
    default would carry public IPv4 or IPv6 around `tun0`; a restart cannot fix
    that, and the tunnel-bound probes alone would not notice it.
16. Warn the same way when the tunnel probe took over 1.5 s on three
    consecutive checks (`TUNNEL_SLOW_SECONDS`, `TUNNEL_SLOW_CHECKS`). One fast
    check resets the count.

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

**Failed restart.** If a single restart does not restore tunnel health and IPv4 reachability, diagnostics are
captured, WARP is stopped, and a five-minute cooldown begins. Runs during the
cooldown maintain direct IPv4 instead of restarting every minute. A healthy
tunnel removes the cooldown marker.

## Observation and game mode

Each failure now logs the failing layer. A live process/interface receives a
second health observation after `TUNNEL_CONFIRM_DELAY` (default three seconds);
a missing process/interface triggers immediate recovery. IPv6 HTTP and latency
are diagnostic measurements, not restart triggers (sustained latency only logs a
warning). IPv6 default-route presence remains a structural requirement.

`game_mode.sh on` prefers direct campus WAN. Policy toggles share the maintenance
lock, and disabling game mode preserves the WAN gateway before removing its
preferred route. Game mode hides IPv6 by rejecting LAN→`tun0` IPv6, not through
DNS: `filter_aaaa` stays 0 in every mode ([[../bugs/known-issues]]).

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

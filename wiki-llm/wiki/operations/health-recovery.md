# Health checking and recovery

Cron runs `ensure_network.sh` at the start and midpoint of every minute. A
directory lock records the owning PID, so staggered jobs cannot overlap. A live
`ensure_network.sh` owner is never displaced; a dead recorded owner is recovered
immediately, while an ownerless maintenance lock must age 180 seconds first.

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
8. Verify direct-WAN IPv4 and run portal login recovery when needed
   ([[portal-login]]).
9. Reject WARP startup when `/tmp` is at or above the configured threshold.
10. Restore the `tun0` rule dropping new inbound connections if a firewall reload
    removed it; never a restart trigger ([[../security/secrets-and-trust]]).
11. Validate process, CONNECT-IP readiness, TUN, default routes, NAT, MSS and
   LAN↔tun0 FORWARD accept rules (missing rules are reinstalled in place and
   logged), and IPv4 HTTP reachability explicitly bound to the tunnel.
12. Confirm live-client failures after three seconds before restarting WARP.
13. Refresh optional host routes independently after a successful health check
    ([[../systems/host-routes]]).
14. Warn (log plus one rate-limited snapshot, no restart) when a lower-metric
    default would carry public IPv4 or IPv6 around `tun0`; a restart cannot fix
    that, and the tunnel-bound probes alone would not notice it.
15. Warn the same way when the tunnel probe took over 1.5 s on three
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
preferred route. LAN IPv6 repair respects game mode's AAAA filtering.

## Operational result

The system prefers full dual-stack WARP, but prioritizes a responsive direct
IPv4 fallback over a configured yet nonfunctional tunnel. See
[[../flows/boot-and-recovery]] for the state flow.

## Sources

- `../../../ensure_network.sh`
- `../../../stop_tunnel.sh`
- `../../../collect_diagnostics.sh`
- `../../../login.sh`
- `../../../paths.sh`

# Health checking and recovery

Cron runs `ensure_network.sh` at the start and midpoint of every minute. A
directory lock records the owning PID, so staggered jobs cannot overlap. A live
`ensure_network.sh` owner is never displaced; a dead recorded owner is recovered
immediately, while an ownerless maintenance lock must age 180 seconds first.

## Check order

Each run first warns when the clock reads earlier than the script's own
modification time. After a reboot the clock can be months behind until NTP
syncs, which breaks lock ageing and TLS; `login.sh` likewise names the clock when
curl reports a certificate failure.

1. Bound project logs when overlay storage crosses the warning threshold.
2. Repair Wi-Fi configuration or reload a configured but down radio.
3. Repair DNS configuration (the four upstreams first and in strict order,
   forwards for exactly the listed campus hosts, portal/SSO address pins, the
   dnscrypt listen address) and the dnsmasq runtime.
4. Repair LAN IPv6 configuration drift.
5. Verify Ethernet carrier and the WAN IPv4 lease before cycling the WAN.
6. Verify the core campus route separately from optional resolved site routes.
   With a healthy lease, a wrong route is fixed by reinstalling `CAMPUS_NETS`
   via the WAN gateway; the WAN is cycled only if that fails, because a cycle
   obtains a new DHCP address and resets every flow.
7. Verify direct-WAN IPv4 and run portal login recovery when needed.
8. Reject WARP startup when `/tmp` is at or above the configured threshold.
9. Validate process, CONNECT-IP readiness, TUN, default routes, NAT, MSS and
   LAN↔tun0 FORWARD accept rules (missing rules are reinstalled in place and
   logged), and IPv4 HTTP reachability explicitly bound to the tunnel.
10. Confirm live-client failures after three seconds before restarting WARP.
11. Refresh optional host routes independently after a successful health check.
12. Warn (log plus one rate-limited snapshot, no restart) when a lower-metric
    default would carry public IPv4 or IPv6 around `tun0`; a restart cannot fix
    that, and the tunnel-bound probes alone would not notice it.
13. Warn the same way when the tunnel probe took over 1.5 s on three
    consecutive checks (`TUNNEL_SLOW_SECONDS`, `TUNNEL_SLOW_CHECKS`). One fast
    check resets the count.

Before the game-mode branch, each run also restores the `tun0` rule that drops
new inbound connections, if a firewall reload removed it. This is never a
restart trigger; see [[../security/secrets-and-trust]]. It is commit `3b3a183`,
deployed on 2026-10-22.

Every Wi-Fi, DNS, and LAN IPv6 repair is followed by a postcondition check.
A repair that still fails captures diagnostics once and enters a five-minute
cooldown (`STAGE_REPAIR_COOLDOWN`; LAN IPv6 has its own), so radios, dnsmasq
and the LAN are not reloaded every tick. Wi-Fi, DNS configuration and LAN IPv6
failures then continue to WAN, portal and WARP recovery. Only a dead resolver
(DNS runtime) still ends the run, because portal logout and WARP restart
decisions depend on probes that need DNS.

## Resource-pressure behavior

The default `/tmp` threshold is 90 percent. At or above it, the pipeline takes a
diagnostic snapshot, removes tunnel routing/process state, restores direct WAN,
and writes a retry-after timestamp. This protects the RAM-backed filesystem and
prevents a failing WARP process from intensifying pressure.

## Failed-restart behavior

If a single restart does not restore tunnel health and IPv4 reachability, diagnostics are
captured, WARP is stopped, and a five-minute cooldown begins. Runs during the
cooldown maintain direct IPv4 instead of restarting every minute. A healthy
tunnel removes the cooldown marker.

## Interactive campus login

The preferred path sends the CC Internet Access token as HTTP Basic Auth and
retains it only across trusted HTTPS redirects. A valid token therefore needs
no CAPTCHA. If the token is expired, revoked, or the portal changes its flow,
the script records an interactive-login marker without logging the page body.
The health loop waits five minutes between token retries instead of logging out
every minute. A browser login remains the last-resort fallback; the next direct
probe detects that portal grant and starts WARP automatically.

Direct IPv4 must fail twice, two seconds apart, before portal recovery starts.
Probes use a two-second connection timeout and four-second total bound. If token
submission ends at `logout.php` while public access is down, `login.sh` treats
that combination as a stale server-side grant: it immediately logs out and
performs a fresh token login. Other responses still receive bounded rechecks
before the session is cleared. This avoids both transient-triggered logouts and
the former dead wait when probes could not repair a stale portal record.

Each failure now logs the failing layer. A live process/interface receives a
second health observation after `TUNNEL_CONFIRM_DELAY` (default three seconds);
a missing process/interface triggers immediate recovery. IPv6 HTTP and latency
are diagnostic measurements, not restart triggers (sustained latency only logs a
warning). IPv6 default-route presence remains a structural requirement.

Optional campus/public DNS exceptions are resolved once per refresh with
three-second lookup bounds. They do not determine WARP liveness. Failed or
partial resolution retains prior routes; stale routes are removed only after
all configured names produced IPv4 answers and route installation succeeded.
This avoids CDN-answer races and partial-DNS-induced tunnel restarts. `tunnel.sh`
only adds these routes when WARP starts and never removes any, so this refresher
is the only remover (commit `dcc7e10`, not deployed as of 2026-10-22). The campus,
public and game-session refreshers can share a `/32` (a game server can also be
a listed public name), so a route is deleted only once no refresher's file lists
it. `refresh_blinkit_dns.sh` runs on every tick, including during WARP
fallback and game mode, when the public refresher does not run. So when the
Blinkit record set changes, it removes the dropped addresses' routes itself,
after publishing the new set. Routes another refresher still lists are left to
that refresher (commit `775bcd4`, deployed on 2026-10-22). Before that, sets
replaced in those states kept their routes until reboot; the router held 20 such
routes, which were removed by hand when the fix was deployed.

`game_mode.sh on` prefers direct campus WAN. Policy toggles share the maintenance
lock, and disabling game mode preserves the WAN gateway before removing its
preferred route. LAN IPv6 repair respects game mode's AAAA filtering.

## Operational result

The system prefers full dual-stack WARP, but prioritizes a responsive direct
IPv4 fallback over a configured yet nonfunctional tunnel. See
[[flows/boot-and-recovery]] for the state flow.

## Sources

- `../../../ensure_network.sh`
- `../../../stop_tunnel.sh`
- `../../../collect_diagnostics.sh`
- `../../../login.sh`
- `../../../refresh_blinkit_dns.sh`
- `../../../paths.sh`

# Known issues and operational limits

These are current constraints rather than silently ignored failures.

## Platform-specific build

The Rust client depends on Linux TUN and netlink facilities. Native compilation
or tests on macOS are not representative; use a Linux container and build the
deployed ARM64 artifact for `aarch64-unknown-linux-musl`.

## Direct fallback is primarily IPv4

When WARP is removed after failure, direct campus IPv4 remains usable. Public
IPv6 may be unavailable until WARP recovers because the WAN does not provide an
equivalent delegated public IPv6 path for LAN clients.

## Storage headroom

Router overlay storage has limited free capacity, while `/tmp` is memory-backed.
At the initial 2026-08-01 audit the overlay was about 85 percent used. After the
user explicitly authorized removal of the unrelated `/root/.claude/remote`
directory, usage fell to about 11–15 percent (rechecked 2026-08-19 at ~15
percent). Project logs and diagnostics remain bounded to 24 retained snapshots
and switch to `/tmp` if their persistent filesystem reaches 97 percent. Manual
files and captures can still create pressure.

## Legacy configuration files

`blocked_sites.txt` and `warp_clients.txt` are retained for rollback and old
tool compatibility. Editing them does not change the active full-tunnel policy.

## External dependencies

Operation depends on IITB portal/DNS availability, Cloudflare registration and
MASQUE endpoints, local dnscrypt-proxy2, and OpenWrt firewall tools. The health
pipeline can recover or fall back but cannot repair an upstream outage.

Portal and SSO hostnames are pinned locally (dnsmasq `address=` plus login
`--resolve`) so a campus-DNS-only outage no longer blocks captive-portal login.
Other campus names still require `10.200.1.11` or public resolvers as configured.

dnscrypt-proxy2 often reports a multi-gigabyte virtual size on OpenWrt; resident
usage is typically tens of megabytes. Prefer RSS over VSZ when judging memory.

The known 2026-08-07 timer spin, 2026-08-09 forwarding starvation, 2026-08-11
stale portal-session, 2026-08-13 LAN IPv6 repair-loop, 2026-08-14 campus-site
policy, 2026-08-19 campus-DNS outage, and 2026-08-20 Mulyankan split-DNS
failures are fixed and documented in
[[warp-cpu-spin-2026-08-07]],
[[warp-forwarding-starvation-2026-08-09]],
[[bgmi-portal-stale-session-2026-08-11]],
[[ipv6-repair-loop-2026-08-13]], [[campus-site-routing-2026-08-14]], and
[[campus-dns-outage-2026-08-19]], and [[mulyankan-internal-dns-2026-08-20]].
The corresponding health, cooldown, DNS, portal-pin, and route controls are
active.

No audit can guarantee that all future failures are impossible. The current
controls remove identified local single points of failure and preserve direct
IPv4 management/fallback, while campus and Cloudflare outages remain external.

## Intermittent games and audit follow-ups

[[game-latency-audit-2026-09-19]] documents deployed recovery hardening and
bounded live verification. Rare game spikes are not yet proven resolved.
The remaining source-review findings were copied Rust integration-test logic,
discarded client lifecycle output, nontransactional full-sync promotion and
ownerless long-running maintenance locks. All four are fixed (audit F36, F37,
F40, F39) and were deployed on 2026-10-23.
No speculative SQM cap was deployed; loaded latency is still unmeasured, and
`measure_load_latency.sh` now measures it.

## DNS filtering on the vendor firmware

The installed dnsmasq 2.85 rejects `--filter-AAAA`, and its init script ignores
`filter_aaaa`. Existing UCI toggles alone do not suppress IPv6 DNS. Game mode no
longer toggles the option (audit F41); it hides IPv6 by rejecting LAN IPv6
forwarding through WARP, which clients treat as a hard error and fall back to
IPv4 at once; Blinkit now uses tested exact
local zones and refreshed IPv4 hosts instead. See
[[blinkit-ipv6-vpn-warning-2026-09-19]]. Clients using independent encrypted DNS
can bypass the router's domain-specific policy.

## Diagnostic sensitivity

Snapshots and packet captures may expose client destinations or topology. Keep
them local, bounded, and sanitized before documentation or sharing.

## Sources

- Workspace and live-router audit on 2026-08-01.
- `../../../PROJECT_CONTEXT.md`
- `../../../ensure_network.sh`
- `../../../usque-rs-optimized/Cargo.toml`
- [[outage-hardening-2026-08-01]]

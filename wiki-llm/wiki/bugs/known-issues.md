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
MASQUE endpoints, local `dnsproxy` (which replaced `dnscrypt-proxy2` on firmware
4.11.0+), and OpenWrt firewall tools. The health pipeline can recover or fall
back but cannot repair an upstream outage.

Portal and SSO hostnames are pinned locally (dnsmasq `address=` plus login
`--resolve`) so a campus-DNS-only outage no longer blocks captive-portal login.
Other campus names still require `10.200.1.11` or public resolvers as configured.

`dnsproxy` (and formerly `dnscrypt-proxy2`) is a Go daemon that often reports a
multi-gigabyte virtual size on OpenWrt; resident usage is typically tens of
megabytes. Prefer RSS over VSZ when judging memory.

The known 2026-08-07 timer spin, 2026-08-09 forwarding starvation, 2026-08-11
stale portal-session, 2026-08-13 LAN IPv6 repair-loop, 2026-08-14 campus-site
policy, 2026-08-19 campus-DNS outage, and 2026-08-20 Mulyankan split-DNS
failures are fixed and documented in
[[warp-cpu-spin-2026-08-07]],
[[warp-forwarding-starvation-2026-08-09]],
[[bgmi-portal-stale-session-2026-08-11]],
[[ipv6-repair-loop-2026-08-13]], [[campus-site-routing-2026-08-14]], and
[[campus-dns-outage-2026-08-19]], and [[mulyankan-internal-dns-2026-08-20]].
The 2026-10-26 BigHome split-DNS omission is fixed and deployed:
[[bighome-internal-dns-2026-10-26]].
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
No speculative SQM cap was deployed.

Loaded latency was measured on 2026-10-23. An upload adds about 30 ms on a quiet
uplink, but 120–150 ms (peaks near 470 ms) when the campus uplink is congested.
The client's TUN-read backpressure does not help (report section 19.10). A
CoDel bound on the client's upload queue (`WARP_UPLOAD_CODEL`, 20 ms) fixed it
in an interleaved router-side test on 2026-10-26: upload-phase tunnel p50 fell
from 500–1,200 ms to 51–52 ms and p95 from 4.5–6.8 s to 0.18–0.25 s, with no
loss of upload throughput. It is now the default; `WARP_UPLOAD_CODEL=0` turns it
off (report section 20).

## DNS filtering on the vendor firmware

The installed dnsmasq 2.85 rejects `--filter-AAAA`, and its init script ignores
`filter_aaaa`. Existing UCI toggles alone do not suppress IPv6 DNS. Game mode no
longer toggles the option (audit F41); it hides IPv6 by rejecting LAN IPv6
forwarding through WARP, which clients treat as a hard error and fall back to
IPv4 at once; Blinkit now uses tested exact
local zones and refreshed IPv4 hosts instead. See
[[blinkit-ipv6-vpn-warning-2026-09-19]]. Clients using independent encrypted DNS
can bypass the router's domain-specific policy.

## 2026-10-26 validation follow-ups

Closed on 2026-11-12: N1 (`rotate_logs.sh` exit status), N2 (`.env` is loaded
before `paths.sh` everywhere), the dnsproxy restart on every tick (now once per
cooldown), A8, A9, A11, A13, and in usque-rs-openwrt C2-C6 and C12. Still open:
a release or commit that fails its health check during an unrelated outage
stays skipped until `--retry-failed`; `configure_dns.sh` writes GL.iNet's
`gl-dns-v2` settings for a reason that is recorded nowhere (A3).

## 2026-11-12 review follow-ups

Fixed: the update gate that passed without testing WARP, the unlocked tunnel
restart after a promotion, the sync that downgraded `usque-rs` or overwrote
`.env`, the WAN cycle on every tick, game mode without an end, the release
pinned by tag only, the missing IPv6 probe (it warns; it does not restart), and
the two log lines every healthy tick wrote to flash (see [[../log]]).

Open, and why:

- The Git updater does nothing until `GITHUB_REPO` is set in the router's
  `.env`, with a token to avoid GitHub's anonymous rate limit. Turning it on
  makes a push to the deploy branch a deployment, which is the owner's call.
- The maintenance lock directory stays on flash (four small metadata writes a
  tick). In `/tmp` it would fail together with a full `/tmp`, the state in which
  the health check is needed most ([[tmp-exhaustion-2026-08-01]]).
- usque-rs still builds on quiche 0.22 and several other crates one or more
  major versions behind; see usque-rs-openwrt's log.

## Client events without their tag in the system log

Up to usque-rs v0.2.4, a client whose PID has exactly four digits logs its
events without the `usque-rs[PID]:` tag, so `logread -e usque-rs` shows nothing
for it: `logd` drops the first 15 characters and a space of each message as a
timestamp, and `usque-rs[4845]: ` is exactly that long. PIDs are that short for
a good while after a reboot. Until a release with the fix (0.2.5) is pinned,
read the events with `logread | grep -e MASQUE -e '\[connecting\]' -e
'\[error\]' -e '\[retry\]' -e '\[fatal\]'`.

## Diagnostic sensitivity

Snapshots and packet captures may expose client destinations or topology. Keep
them local, bounded, and sanitized before documentation or sharing.

## Sources

- Workspace and live-router audit on 2026-08-01.
- `../../raw/sources/project-context-2026-10-25.md`
- `../../raw/sources/audit/2026-10-26-validation/REPORT.md`
- `../../../ensure_network.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/Cargo.toml`
- [[outage-hardening-2026-08-01]]

# Router reliability audit — 19 September 2026

The recovery scripts contained avoidable disconnect paths. Nine corrected
runtime scripts are deployed with rollback copies, without restarting Wi-Fi,
DNS, or the existing WARP process. The intermittent game issue is **not yet
proven eliminated**: no in-game spike was captured during this audit.

## Evidence

- User reports BGMI on iPhone and Clash Royale on iPad, mostly on 5 GHz.
- September 18 logs show 12 watchdog WARP restarts, plus direct-WAN/portal
  recoveries. Old restart messages do not identify the failed health predicate;
  they cannot establish which restarts were necessary or caused a game spike.
- Initial campus gateway sample: 15/15 replies; average 0.751 ms, max 0.828 ms.
- Initial public ping over WARP: 15/15 replies; average 3.948 ms, max 5.570 ms.
  This is not the game server's RTT and does not include client Wi-Fi.
- Router uptime was 16 days, load low, available memory approximately 278 MiB,
  `/tmp` 1% used and overlay 15% used. Queue snapshots had no backlog.
- Connected 5 GHz clients had strong signals (approximately -20 to -31 dBm).
  This does not rule out intermittent interference or device power saving.
- Existing fq_codel queues are present; no measured bandwidth shaper was shown.

## Changes installed

| Area | Defect | Change |
|---|---|---|
| WARP recovery | A live client's transient readiness/probe failure triggered teardown | Confirm after three seconds and log the failing layer; missing process/interface still recovers immediately |
| Optional routes | DNS answers were fetched again after installation, potentially differing and triggering a global restart | Resolve once and refresh separately from tunnel health |
| Partial DNS outage | One successful domain permitted deleting another domain's unresolved routes | Preserve the old set unless all configured domains resolve and install successfully |
| DNS operations | Several lookups had no explicit time bound | Three-second lookup bounds in maintenance, startup and diagnostics |
| Health measurements | A default-path request could test a bypass instead of WARP | Bind WARP probes explicitly to the tunnel interface |
| Game mode | Watchdog could race toggles; disabling could delete the only WAN default | Share maintenance lock and install fallback before deleting preferred WAN route |
| IPv6 repair | Repair could undo game mode's AAAA filter | Respect the active game-mode marker |
| DNS pins | Config writer ignored portal/SSO overrides that health checks expected | Use matching overrides and remove old pins for those exact domains |
| Diagnostics | Hard-coded historical phones/gateway, faulty failure parsing, nominal rather than actual duration | Optional client IP, discovered gateway, parallel bounded WAN/WARP samples, HTTP/transport distinction, wall-clock duration, bounded logs |
| Launcher | Configurable TUN name was not passed to the client | Pass `--interface-name` |

`sync_to_router.sh` was improved locally: uploads now finish before stopping
WARP, and interrupts return failure. Its router copy differs from the Mac copy
and was intentionally not overwritten. Normal full deployment still restarts
WARP; this audit used a checked script-only deployment.

## Validation

- All top-level shell scripts pass `sh -n` locally.
- Nine staged runtime scripts passed router shell syntax and old/new SHA-256
  checks before promotion under the maintenance lock.
- Eight regression tests exercise actual shell functions/blocks: transient vs
  persistent failure, missing process, optional-route independence, partial/full
  DNS refresh, sole-WAN-default preservation, and monitor HTTP classification.
- A live updated health run passed. WARP PID remained 7662 across deployment
  and verification; preferred WARP and fallback WAN defaults were preserved.
- Six paired samples across 30 seconds all returned HTTP 204: direct WAN
  approximately 59–74 ms; WARP 80–110 ms, including DNS/TCP/TLS setup.
  Gateway samples lost no packets. An explicit tunnel IPv6 request returned 204.
- No load/speed test was run while the user might be playing. No router-wide
  direct-game policy, Wi-Fi channel change, or speculative rate cap was applied.
- ShellCheck was unavailable. Docker's Linux engine was unavailable; the Rust
  binary was not rebuilt, changed, or deployed. Native macOS compilation cannot
  validate the Linux TUN/netlink program.

## Broader review and remaining work

Reviewed runtime/configuration/deployment shell scripts, the Rust client modules,
manifest and tests, project documentation and linked operational/incident wiki.
Generated build output and historical binary contents were excluded. This is a
source review and bounded live check, not proof of every possible failure mode.

1. **Campus authorization outages remain external.** Logs show real login
   recoveries. Router fixes can shorten recovery, but cannot guarantee uninterrupted
   sessions through a campus outage. Direct game mode also depends on the portal.
2. **Measure latency under load before enabling SQM.** Existing fq_codel does not
   establish control of a slower upstream bottleneck. Compare wired idle/loaded
   latency and WAN versus WARP; only then select shaping rates. OpenWrt documents
   [SQM](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm) and
   [measurement guidance](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm-details).
3. **Rust observability/test gaps.** Runtime client output is discarded. A bounded
   event-only log would help explain disconnects without restoring per-second
   flash writes. The MTU integration file copies production packet/ICMP logic,
   so those tests can pass while real code differs; privileged tests skip if TUN
   creation fails. Validate future binary work in Linux with real TUN coverage.
4. **Rust edge cases.** ICMPv4 errors quote a fixed 20-byte header plus eight
   bytes, rather than honoring IPv4 options. TUN write errors are ignored, and
   HTTP/3 CONNECT stream-close events are ignored in the established loop.
   These deserve targeted Linux tests before changing the deployed client;
   none is established as the current game's failure cause.
5. **Deployment limitations.** Full sync promotion uses individual file moves,
   not an all-files transaction. Ownerless maintenance locks can be reclaimed
   after 180 seconds, so a slow full upload/registration deserves an owner-aware
   locking redesign. This script-only deployment completed well within the limit.
6. **Startup route maintenance differs from periodic refresh.** The launcher
   still clears dynamic exception state before resolving it. The periodic
   refresh now preserves partial-DNS state; sharing that implementation with
   startup is a future cleanup that requires rollback-path testing.
7. **Trust documentation was wrong.** Login intentionally forwards Basic Auth
   across HTTPS redirects via `--location-trusted`; the wiki incorrectly denied
   this. Documentation now reflects the actual campus trust dependency.

## Follow-up capture

On the router, while the affected device is awake and playing:

```sh
DURATION=300 INTERVAL=5 PHONE_IP=<current-device-LAN-IP> sh monitor_game_network.sh
```

Record the exact time of a spike. Compare it against `logs/game_monitor.log`
and the newly specific `logs/ensure.log`. A sleeping client's missing ping is
not sufficient evidence of Wi-Fi loss. The monitor stops automatically; this
audit did not leave a background monitor running.

## Rollback and review

Router originals: `/root/router-script/audit-backup-20260919/`.
Local originals: `audit/2026-09-19/before/`; reviewed diff: `changes.patch`.
Restore the affected scripts under the same maintenance lock; no secret files
or Rust binaries were changed. Tests: `python3 -m unittest discover -s tests -v`.

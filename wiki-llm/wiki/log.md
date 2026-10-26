# Wiki and audit log

Append new entries at the end. Preserve older entries as historical evidence.

## 2026-08-01 — initial Wiki-LLM bootstrap

- Inventoried all top-level shell scripts, data files, documentation, and binaries.
- Inventoried the full `usque-rs-optimized` Rust source and build metadata.
- Audited the live GL-MT3000 router at `192.168.8.1` without recording secrets.
- Confirmed full public IPv4 and IPv6 routing through WARP.
- Confirmed campus-private IPv4 routing directly through the physical WAN.
- Confirmed `sso.iitb.ac.in` and `internet.iitb.ac.in` resolve to campus space.
- Diagnosed `/tmp` exhaustion caused by two abandoned packet captures.
- Removed only the stale router-side captures and their exact processes.
- Added WARP reconnect backoff and handshake deadlines.
- Added health-check resource limits, cooldown, and direct-WAN fallback.
- Made WARP config writes atomic and mode `0600`.
- Made synchronization staged, locked, and failure-safe.
- Corrected noninteractive registration and absolute config-path handling.
- Required endpoint certificate key pinning instead of optional validation.
- Made DNS upstream selection deterministic with `noresolv=1`.
- Increased log rotation frequency from daily to every six hours.
- Marked the old split-routing proposal as superseded.
- Created this wiki with no secret material and no copied diagnostics.

## 2026-08-01 — deployment verification

- Cross-built the static ARM64 OpenWrt binary and matched both deployment copies.
- Passed Rust formatting, strict Clippy, 39 unit tests, and 23 integration tests.
- Corrected a BusyBox portability error discovered by staged deployment.
- Verified failed deployments removed their staging state, released locks, and
  restarted the previously active tunnel.
- Deployed the corrected scripts and binary through the staging transaction.
- Verified mode `0600` on both router-side secret files without reading values.
- Verified public IPv4 and IPv6 report WARP enabled.
- Verified both campus applications route directly and return HTTP redirects.
- Forced the resource-pressure path, confirmed direct IPv4 fallback and retry
  cooldown, then restored WARP and passed six consecutive minute health checks.

## 2026-08-01 — Wi-Fi stability follow-up

- Isolated recent transmit failures to the MediaTek radio/client link; tunnel
  and queue counters showed no corresponding drops.
- Found the live radios incorrectly configured for regulatory country `US`.
- Replaced 2.4 GHz `HE40` and 5 GHz `HE160` with `HE20` and `HE80` policy.
- Added idempotent Wi-Fi configuration and health-check drift repair.
- Verified the running driver adopted channels 8/48 at HE20/HE80.
- Observed no new transmit-failure burst after the profile reload.
- Measured 0 percent IPv4/IPv6 loss, about 3.8 ms average tunnel RTT, 20 of 20
  successful UDP DNS queries, and roughly 80–94 Mbps WARP download throughput.

## 2026-08-01 — IITB portal migration

- Initial diagnosis found that unauthenticated portal requests redirect to SSO
  with CAPTCHA/possible OTP.
- Confirmed both public TCP and WARP UDP transport are blocked before login.
- A controlled follow-up proved that access-token authentication still works,
  but only when Basic Auth is forwarded across IITB's HTTPS redirect chain.
- The retired `internet-sso.iitb.ac.in` hostname no longer resolves; the merged
  flow begins at `internet.iitb.ac.in/login.php` and redirects through IITB SSO.
- Updated token login to use HTTPS-only trusted redirects. Interactive SSO and
  its runtime marker remain the fallback for an expired or revoked token.
- Fixed log rotation to retain only a bounded tail after obsolete portal HTML
  grew beyond the configured limit.

## 2026-08-01 — Dual Mac management links

- Put `iPhone USB` before `Wi-Fi` in macOS network-service order.
- Verified USB remains the default internet route while `192.168.8.0/24` stays
  directly reachable over Wi-Fi for router SSH and recovery work.

## 2026-08-01 — Campus-only CC page routing

- Found `www.cc.iitb.ac.in` uses split-horizon DNS: campus DNS returns private
  `10.100.117.18`, while public DNS returns `103.21.124.6`.
- Added `cc.iitb.ac.in` to campus DNS forwarding and a direct-WAN exception for
  the public address, preventing IITB's source-IP gate from seeing WARP egress.
- Added dynamic public-host exception state and route-drift validation.
- The temporary Mac service-order experiment was reverted. No Mac host route
  was installed; the final campus-site policy is implemented only on the router.

## 2026-08-01 — Hostel 01 network reference imported

- Preserved the user-supplied Computer Centre Hostel IP/HOP screenshot under
  `raw/assets/`.
- Added [[systems/campus-wan]] with the Hostel 01 Wing 1 Floors 0/1 DHCP pool,
  `/19` mask, gateway, DNS server, and five published campus hops.
- Linked the reference into architecture, DNS, routing, sources, and the wiki
  index. The page explicitly keeps campus exceptions router-side.

## 2026-08-01 — Full outage-hardening audit and deployment

- Audited every top-level shell script, every Rust WARP module, and live router
  state across WAN, Wi-Fi, DNS, portal, WARP, firewall, IPv4, and IPv6 layers.
- Added explicit CONNECT-IP readiness and delayed public defaults until ready;
  live startup reached readiness in about one second.
- Corrected the inert QUIC keepalive, reconnect task leak, immediate-connect
  behavior, IPv4 IHL validation, and options-bearing header checksums.
- Made startup failure rollback, lock ownership, signal handling, interrupted
  WARP rotation, staged pulls, and partial diagnostic/rotation output safe.
- Added Wi-Fi runtime, DNS runtime, carrier, post-repair, storage, and optional
  campus-route health distinctions.
- Passed formatting, strict Clippy, 41 unit tests, 23 integration tests,
  ShellCheck, router BusyBox syntax checks, and an isolated CONNECT-IP smoke test.
- Deployed binary SHA-256 `fef2ede08a4e7b9b0065ad8bf263d640ba10304f45a7187ed3e28a6e0598cad0`.
- Verified repeated health passes, exact direct/WARP IPv4 and WARP IPv6 `204`
  probes, matching process/readiness PID, NAT/MSS rules, and live radios.
- Verified the CC hostel page returns `200` at its private campus address from a
  Wi-Fi client while public IPv4 and IPv6 remain on WARP.
- Reduced normal diagnostics from 60 to the retained 24, recovering overlay
  headroom, and sanitized four old router files containing OAuth callback URLs.
- Preserved the Mac's existing network configuration; all routing changes are
  implemented on the router.

## 2026-08-01 — Router overlay cleanup

- Verified `/root/.claude/remote` was a directory occupying 224,616 KiB by
  apparent file size and that its exact parent resolved to `/root/.claude`.
- Removed only that directory after explicit user authorization.
- Overlay usage fell from 85 percent to 11 percent, with about 138 MiB free.
- Re-ran the health pipeline and verified WARP IPv4 and IPv6 remained healthy.

## 2026-08-07 — WARP CPU-spin and sluggishness repair

- Confirmed the campus gateway, direct WAN, DNS, storage, and Mac 5 GHz link
  were healthy while WARP added `0.7–1.3 s` to HTTPS requests.
- Measured 961 `usque-rs` CPU ticks over ten seconds at only about `1.7 Mbps`,
  proving an event-loop spin rather than legitimate throughput saturation.
- Added a 5 ms floor to expired quiche event-loop timers while preserving
  immediate TUN and UDP wakeups.
- Made tunnel recovery use one pre-restart and one post-restart health result.
- Required two direct failures before portal recovery and added three bounded
  post-token checks before any forced logout.
- Passed 42 ARM64 unit tests, 23 integration tests, strict Clippy, formatting,
  ShellCheck, and shell syntax validation using offline build containers.
- Deployed binary SHA-256
  `524622a66b7a164cade315242aca7d1902deab6df9c44fe8150b28cc8cd43664`.
- Verified settled CPU fell to 26 ticks per ten seconds, HTTPS to `72–82 ms`,
  router WARP throughput to about `139 Mbps`, and client throughput to `96 Mbps`.
- Verified portal authentication, campus bypass, public IPv4/IPv6, DNS, Wi-Fi,
  readiness PID, and the complete health pipeline after deployment.

## 2026-08-09 — WARP forwarding-starvation repair

- Reproduced WARP latency of `1.5–4.2 s`, 968 CPU ticks per ten seconds, and a
  135,936-byte UDP receive backlog while the direct campus path remained fast.
- Found that the unbounded post-event UDP drain could monopolize the forwarding
  loop and starve CONNECT-IP delivery and outbound QUIC processing.
- Capped all forwarding stages at 64 items and added cooperative continuation.
- Added repeated latency-sensitive health probes so reachable-but-sluggish WARP
  sessions are no longer accepted as healthy indefinitely.
- Passed 43 ARM64 unit tests, 23 integration tests, strict Clippy, formatting,
  ShellCheck, and shell syntax validation.
- Deployed binary SHA-256
  `52fab7c15f9069840631f309dd574657445253837535e8df9763af444a4183c2`
  with timestamped rollback copies.
- Verified zero UDP backlog, 13 settled CPU ticks per ten seconds after a
  minute-long transfer, `69–75 ms` HTTPS probes, IPv4, IPv6, campus bypasses,
  readiness, and the complete health pipeline.

## 2026-08-09 — Final QUIC pacing and BBR2 correction

- A later Fast.com report reproduced `4.5 Mbps`; macOS independently measured
  `5.7 Mbps` down, `11.4 Mbps` up, and `154 ms` idle latency.
- Confirmed the Wi-Fi PHY was `1.2 Gbps`, the campus gateway was `0.72 ms` with
  zero loss, and the same object transferred at about `51 Mbps` directly but
  only `4.2 Mbps` through WARP.
- Found that future quiche `SendInfo::at` pacing deadlines were ignored, causing
  burst loss and progressive congestion-window collapse after a fresh session.
- Added paced packet retention as a first-class event-loop timer branch.
- Benchmarked CUBIC, BBR, BBR2, and Reno. CUBIC immediately regressed and pinned
  a CPU core; BBR2 was consistent, used the least CPU, and kept `Recv-Q` empty.
- Persisted `WARP_CC=bbr2` locally and on the router with a protected rollback.
- Passed 44 ARM64 unit tests, 23 integration tests, strict Clippy, formatting,
  and shell validation; deployed binary SHA-256
  `1ee312fc8c64de8a06015034215b9bc0226457e8ac1959d6a1b933c4a194c7e9`.
- Verified `66.0 Mbps` down, `40.2 Mbps` up, `19 ms` idle latency, six stable
  post-selection transfers, zero UDP backlog, and a passing health pipeline.

## 2026-08-11 — BGMI portal stale-session recovery

- Correlated the BGMI 65-percent match-load failure with a campus public-access
  outage beginning at 22:10, rather than with WARP, Wi-Fi, NAT, or MTU failure.
- Confirmed the access-token request reached `logout.php` while public probes
  remained down: the token was accepted, but IITB retained a stale session whose
  forwarding grant had expired.
- Verified the active phone had a strong radio link and that the core UDP/20000
  match flow was bidirectional and conntrack `ASSURED` after portal recovery.
- Made `login.sh` immediately logout and re-login on the stale-session signature;
  shortened bounded direct probes, confirmation, and settling intervals.
- Staggered `ensure_network.sh` at both the start and midpoint of every minute,
  retaining its existing overlap lock and interactive-login fallback marker.
- Passed shell syntax and ShellCheck, deployed with timestamped rollback copies,
  and verified consecutive :00/:30 health passes without restarting WARP.
- Preserved full public IPv4/IPv6 WARP routing, campus-direct exceptions, and the
  Mac's configuration; no speculative game endpoint bypass was added.

## 2026-08-13 — LAN IPv6 recovery-loop repair

- Found direct campus connectivity healthy while the watchdog reloaded LAN every
  30 seconds and exited before portal authentication or WARP startup.
- Traced the trigger to an empty runtime ULA `local-address` after restart; the
  configured prefix assignment did not put a global IPv6 address on `br-lan`.
- Persisted an explicit ULA `/64` LAN address and enabled IPv6 before applying
  the interface configuration.
- Made failed IPv6 repair nonfatal and rate-limited for five minutes so it cannot
  block IPv4/WARP recovery or repeatedly interrupt both Wi-Fi radios.
- Passed shell syntax and ShellCheck, deployed with timestamped rollback copies,
  and verified matching hashes plus successive watchdog health passes.
- Verified direct IPv4, WARP IPv4/IPv6, campus DNS, router-issued client IPv6,
  and Wi-Fi-bound dual-stack HTTP probes at about `42 ms`.
- Made no changes to the Mac's network configuration.

## 2026-08-14 — Moodle and ASC campus routing

- Reproduced four-second timeouts for Moodle and ASC Portal through WARP while
  direct campus HTTPS returned in about `66–71 ms`.
- Confirmed IITB DNS returned private split-horizon answers but router/client
  public DNS answers selected WARP because both domains were absent from policy.
- Added Moodle and ASC to campus DNS forwarding and direct-domain validation.
- Routed IITB's public `103.21.124.0/22` through campus so cached public DNS
  answers also work without client-side changes.
- Deployed DNS/routes live without restarting WARP or Wi-Fi and retained
  timestamped rollback copies.
- Verified exact URLs from the Wi-Fi client, matching WARP readiness PID,
  healthy public WARP IPv4/IPv6, and subsequent watchdog passes.

## 2026-08-19 — campus DNS outage and portal pin

- Diagnosed room egress loss while corridor WAN stayed usable: campus DNS
  `10.200.1.11` was down and captive-portal hostnames failed to resolve.
- Verified portal `10.201.250.201` and SSO `10.200.1.100` remain reachable on
  the internal campus network; temporary `/etc/hosts` pins restored login.
- Fixed dnscrypt-proxy bind/config restore so DoH fallback listens on
  `127.0.0.1:5453` instead of colliding with dnsmasq on port 53.
- Pinned portal/SSO in dnsmasq `address=` records via `configure_dns.sh` and
  added curl `--resolve` fallbacks in `login.sh`.
- Removed temporary `/etc/hosts` pins after deploy; verified pinned answers,
  active internet via `login.sh`, and public DNS through the router chain.
- Documented the incident in [[bugs/campus-dns-outage-2026-08-19]].

## 2026-08-19 — post-repair audit

- Live router: load ~0, overlay ~15 percent, WARP on, dual default metrics
  (tun0/5, eth0/10), campus `10/8` and `103.21.124.0/22` direct, health pass.
- dnscrypt-proxy RSS ~17 MB (VSZ is misleadingly large); usque-rs RSS ~4 MB.
- Extended `ensure_network.sh` DNS drift checks for portal/SSO pins and
  dnscrypt listen address; verified auto-repair after intentional pin removal.
- Updated `dns_flow.sh` and wiki pages (overview, architecture, dns, campus-wan,
  script-map, health-recovery, known-issues) for portal-pin policy.
- Noted only management-script drift: router `sync_to_router.sh` /
  `sync_from_router.sh` older than workspace (not on the health path).

## 2026-08-20 — Mulyankan internal DNS exception

- Confirmed Mulyankan is internal-only: IITB DNS returned a private address while
  public DNS did not provide a usable answer; direct campus HTTPS was healthy.
- Added the hostname to the campus DNS and direct-domain policy and applied DNS
  live without restarting WARP or Wi-Fi.
- Found the affected Mac was manually using Google DNS, bypassing router
  split-DNS. After it returned to router-provided DNS, client resolution and
  HTTPS succeeded.
- Verified router/client access, stable WARP readiness, passing health checks,
  local shell validation, and timestamped router rollback copies.
- Deliberately omitted the reset URL, token, email address, and account data.

## 2026-09-10 — Blinkit direct-WAN exception

- Captured only bounded iPhone DNS/TLS metadata while Blinkit was freshly
  launched; observed `api3.blinkit.com`, `jumbo.blinkit.com`, and Sentry.
- Confirmed these public endpoints selected WARP before the change and were
  reachable through the physical WAN afterward.
- Added refreshable direct-public host routes with health verification and
  rollback cleanup. Temporary packet captures were deleted after analysis.
- Documented the IPv6 limitation: the campus WAN has no native global IPv6,
  so the observed IPv4 Blinkit sessions are bypassed while IPv6 remains WARP.

## 2026-09-12 — Webmail split-DNS repair

- Diagnosed webmail failure as a split-horizon DNS omission: public DNS led to
  an IITB Squid `503`, while campus DNS and HTTPS to the internal address were
  healthy.
- Added `webmail.iitb.ac.in` to campus DNS forwarding and direct-domain route
  checks; applied dnsmasq live and verified HTTP `200` plus a passing health run.
- No client/Mac network settings were changed.

## 2026-09-17 — Gemini direct-WAN exception

- Diagnosed Gemini's unusual-traffic page as WARP/shared-egress reputation with
  dual-stack WARP exits; router defaults and native IPv6 state were verified.
- Added `gemini.google.com` to the direct-public route policy and deployed it.
- Current Gemini IPv4 routes select the campus WAN, HTTP returns `200`, and the
  health pipeline passes. No Mac network settings were changed.

## 2026-09-22 — Clash Royale game-port exception

- Captured iPad DNS and packet headers and identified repeated Supercell game
  session SYNs to TCP port 9339.
- Confirmed WARP timed out while the campus WAN connected immediately.
- Added observed Clash Royale/Supercell domains to the dynamic direct-public
  route policy, then added policy routing for TCP/UDP 9339 so dynamic session
  endpoints use the campus WAN from their first packet; health and route
  verification passed after deployment.
- Removed the temporary packet capture; no client settings changed.

## Maintenance protocol

- Record deployed changes only after verification.
- Link new incident pages from [[index]] and [[bugs/known-issues]].
- Update [[sources]] when the codebase gains or removes a component.
- Keep this log append-only.

## Sources

- Workspace audit performed 2026-08-01.
- Live read-only router inspection and bounded integration checks.
- `../../.claude/plan.md`


## 2026-09-19 — Game latency audit and recovery hardening

- Inspected live router and shell/Rust source; found 12 prior-day WARP restarts
  plus portal recoveries, without historical per-check failure reasons.
- Deployed nine runtime script fixes under a short maintenance lock, retaining
  originals at `/root/router-script/audit-backup-20260919/`; WARP PID unchanged.
- Added confirmation and failure reasons, independent DNS-route refresh,
  partial-DNS preservation, bounded lookups, game-mode fixes and improved probes.
- Eight regression tests, router syntax/hash checks and live health/dual-stack
  probes passed. A 30-second latency capture showed no gateway loss.
- Updated stale trust/health documentation. Rust binary unchanged; Linux build
  engine unavailable. Rare in-game spikes remain unverified as resolved.
- See [[bugs/game-latency-audit-2026-09-19]] for evidence and remaining work.

## Sources

- `../../audit/2026-09-19/REPORT.md`
- `../../tests/test_network_recovery.py`
- Live router verification on 2026-09-19.


## 2026-09-19 — Blinkit VPN warning and scoped DNS repair

- User reported an explicit VPN warning and confirmed no iPhone VPN enabled.
- Verified that Blinkit IPv6 still used WARP despite the earlier IPv4 bypass.
- Tested local-zone plus IPv4-host DNS behavior on an isolated loopback port;
  deployed it for the two known API names with upstream refresh and saved-record
  fallback. General IPv6 and the WARP process remained intact.
- Thirteen regression tests passed. Router DNS/route checks passed after deploy;
  phone-side success is not inferred from those checks.
- Corrected documentation: installed dnsmasq 2.85 ignores the existing UCI
  `filter_aaaa` setting. See [[bugs/blinkit-ipv6-vpn-warning-2026-09-19]].

## Sources

- `../../refresh_blinkit_dns.sh`
- `../../tests/test_blinkit_dns.py`
- User screenshot and live router checks on 2026-09-19.


## 2026-09-19 — Blinkit repair not sufficient

- User reported continued Blinkit failure after the scoped IPv4 DNS change.
- Rechecked active DNS policy and successful scheduled health runs; neither
  establishes app success. Corrected incident status to unresolved.
- Direct and WARP unauthenticated endpoint responses are not an app acceptance
  test. Awaiting a correlated phone launch and mobile-data comparison.

## Sources

- User follow-up and router checks on 2026-09-19.
- [[bugs/blinkit-ipv6-vpn-warning-2026-09-19]]


## 2026-09-19 — Captured missing Blinkit legacy API

- User confirmed the warning appears on Wi-Fi only, not mobile data.
- A bounded affected-iPhone capture observed TLS SNI `api2.grofers.com` in
  addition to api3/jumbo Blinkit. Its IPv4 destination still selected WARP.
- Added the observed legacy name to scoped IPv4 DNS and direct-WAN defaults;
  deployed with rollback copies, preserving the WARP process and Wi-Fi.
- Fourteen regression tests and live A/AAAA/route checks passed. Root-path
  HTTP 403 from both exits is not an app acceptance test. A refreshed phone
  retry is required before declaring Blinkit resolved.

## Sources

- [[bugs/blinkit-ipv6-vpn-warning-2026-09-19]]
- `../../tests/test_blinkit_dns.py`
- `../../audit/2026-09-19-blinkit-followup/`


## 2026-09-23 — Google/YouTube IITB WAN bypass

- User requested Google services through IITB after a YouTube bot warning.
- Installed published Google service ranges plus domain-learned destination sets,
  IPv4 table 102, and scoped IPv6 rejection for prompt IPv4 fallback.
- Preserved explicit WARP health probes; no WARP restart or Wi-Fi reload needed.
- Fixed an unset LAN subnet default exposed in existing game-policy maintenance.
- Verified direct routes, successful HTTP checks, healthy monitoring and unchanged
  WARP process. Warning disappearance still requires user app confirmation.
- Updated architecture, routing flows, script map, sync manifest, and regression tests.

## Sources

- [[systems/google-wan]]
- `../../audit/2026-09-23-google/`


## 2026-10-08 — OpenCode Post-Quantum TLS & bidirectional TCP MSS clamping

- Diagnosed `SSL_ERROR_BAD_MAC_READ` / `decryption failed or bad record mac` on
  `opencode.ai` and `api.opencode.ai` through WARP.
- Falsified IP ban hypothesis: unauthenticated curl through WARP returns HTTP 200.
- Isolated failure to modern Post-Quantum key exchange (`X25519MLKEM768`)
  expanding ClientHello to ~1540 bytes, exceeding tunnel MTU (1280).
- Found `tunnel.sh` clamped MSS only on outbound SYN (`-o tun0`). Inbound SYN-ACK
  from the server was unclamped, causing LAN clients to retain MSS 1460 and
  transmit 1500-byte IP packets which fragmented over `tun0` and desynchronized
  at Cloudflare's MASQUE Anycast edge.
- Added inbound TCP MSS clamping on `tun0` for IPv4 (`--set-mss 1240`) and IPv6
  (`--set-mss 1220`) in `tunnel.sh` and `stop_tunnel.sh`.
- Added in-place MSS rule verification and repair in `ensure_network.sh`.
- Passed 21 regression tests; deployed to router under lock; WARP PID preserved.
- Verified OpenSSL ML-KEM handshakes, Python urllib, and live web access.

## Sources

- [[bugs/opencode-pqc-mss-clamping-2026-10-08]]
- `../../audit/2026-10-08-mss-clamping/`
- `../../tunnel.sh`, `../../stop_tunnel.sh`, `../../ensure_network.sh`
- `../../tests/test_network_recovery.py`


## 2026-10-17 — Wiki/code consistency repair

- Read-only review of the wiki against current scripts; no router changes.
- `systems/dns.md`: added `webmail.iitb.ac.in` to the campus-forwarded list,
  matching `CAMPUS_DOMAINS` in `configure_dns.sh`.
- `operations/deployment.md`: corrected the bootstrap order; Wi-Fi runs first and
  login/WARP start happen through the `ensure_network.sh` pass, not directly.
- `sources.md`: listed Wi-Fi, Google, Blinkit, game-mode and game-monitor
  scripts, Google policy data files, `tests/`, and `audit/`.
- `systems/script-map.md`: added `monitor_game_network.sh`.

## Sources

- `../../configure_dns.sh`, `../../bootstrap_router.sh`
- `../../monitor_game_network.sh`, `../../game_mode.sh`


## 2026-10-20 — Full review and approved fixes (not yet deployed)

- Read-only audit of all scripts, the Rust client, logs and diagnostics: 30
  findings. The local logs/diagnostics date from the 2026-08-01 pull.
- Found that diagnostics recorded both Wi-Fi WPA2 passphrases, and that a stuck
  Wi-Fi/DNS stage blocked all WAN, portal and WARP recovery.
- Found that LAN↔`tun0` FORWARD rules were never repaired, that WARP rotation
  always rolled back, and that the game policy was rebuilt every tick.
- Fixed on branch `full-review-2026-10-20` with test-first commits: F01, F02,
  F03, F04, F05, F06, F07 (log only), F08, F09, F11, F15. Verified with 48
  sandboxed tests and shellcheck. **Not deployed:** the router still runs the
  previous scripts until the report's deployment checklist is followed.
- Wiki pages changed with the fixes: `operations/health-recovery.md`,
  `operations/diagnostics.md`, `operations/warp-rotation.md`,
  `security/secrets-and-trust.md`.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md`
- `../../tests/sandbox.py`, `../../tests/test_pipeline.py`
- `../../ensure_network.sh`, `../../diagnose.sh`, `../../login.sh`


## 2026-10-20 — Deployed the full-review fixes

- With the user's authorisation, deployed the six changed scripts. Step A
  (diagnostics, login, Google policy and rotation scripts) went in at 21:16
  IST; step B (`ensure_network.sh`) at 21:19. Both were promoted under the
  maintenance lock without restarting WARP (PID 4495 unchanged).
- Before promotion, the router's scripts matched the review baseline. Each
  new mechanism was dry-run read-only against live data first: BusyBox
  `sed`/`awk`, curl 7.83.1 `-K -`, the `iptables -S`/`-C` game-chain check,
  and Cloudflare's trace (`warp=on` for both families through `tun0`).
- Every health tick passed afterwards. The game-policy PREROUTING jump counter
  now grows instead of resetting every 30 s.
- Redacted the Wi-Fi passphrases in the 25 existing router snapshots (50
  values, each file verified before replacement). All snapshots are now
  mode `0600`.
- Backup and rollback: `/root/router-script/backup-20261020`; the commands
  are in the report's section 11. A real portal re-login (F05) has not
  happened yet.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 13)
- `../../ensure_network.sh`, `../../login.sh`, `../../diagnose.sh`

## 2026-10-22 — Batch 4 of the full review (implemented, not deployed)

- With the user's approval, implemented F13, F14 and F21 (log only), F19, F20,
  F22, F23, F25 and F26–F30, each as one test-first commit. F24 is documented
  on the new page [[systems/policy-routing]]. Nothing was deployed; the router
  still runs the 2026-10-20 set.
- Corrected F12: the public refresher already removes replaced Blinkit
  addresses, because it resolves those names through dnsmasq's Blinkit hosts
  file. A sandbox test now pins that dependency.
- F22 now enforces the DNS invariant (upstream order, and only the listed
  campus forwards). F19's test showed that the SIGHUP trap alone left a
  rotation unrestored, because `cleanup`'s log write failed on the lost
  terminal; that write is now non-fatal.
- Added the first tests for `sync_to_router.sh` (stub ssh/scp against a
  temporary directory) and for SIGHUP handling. 72 tests pass under `sh` and
  `dash`; shellcheck findings are unchanged.
- The wiki pages this batch's code contradicted were repaired in a follow-up
  commit, not in the same commits as the contract asks.
  `operations/health-recovery.md` is now 113 lines, above the preferred 80 (it
  was 99).
- The deployment steps, a read-only DNS-order gate and the rollback commands
  are in the report's section 14.4.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 14)
- [[systems/policy-routing]]
- `../../ensure_network.sh`, `../../sync_to_router.sh`, `../../rotate_tunnel_ip.sh`, `../../refresh_blinkit_dns.sh`
- `../../tests/test_sync.py`, `../../tests/test_hangup.py`

## 2026-10-22 — Deployed batch 4; F12 confirmed live and fixed (fix not deployed)

- With the user's authorisation, deployed the six batch-4 router scripts
  (step A at 00:44, `ensure_network.sh` at 00:45) under the maintenance lock.
  WARP was not restarted (PID 20421 throughout), and every health tick
  passed. The rollback binary was already on the router and identical, so
  nothing was installed for F25. Backup: `/root/router-script/backup-batch4`.
- The read-only DNS-order gate for F22 passed on the live list.
- **Correction to the previous entry:** its F12 statement was wrong. The
  post-deploy ownership check found 20 leaked CloudFront routes from earlier
  `api3.blinkit.com` answers. The public refresher removes replaced Blinkit
  routes only on healthy ticks, so sets replaced during WARP fallback or game
  mode kept their routes.
- Fixed in commit `775bcd4`: `refresh_blinkit_dns.sh` now removes the routes
  of the addresses it drops, after publishing, unless another refresher still
  lists them. There are new end-to-end tests for both leak paths. The fix and
  a one-time removal of the 20 routes await deployment; the user chose to
  leave the routes until then.
- Updated [[operations/health-recovery]] and
  [[bugs/blinkit-ipv6-vpn-warning-2026-09-19]].

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 15)
- `../../refresh_blinkit_dns.sh`
- `../../tests/test_blinkit_dns.py`, `../../tests/test_pipeline.py`

## 2026-10-22 — Deployed the F12 fix and removed the leaked Blinkit routes

- With the user's authorisation, promoted `refresh_blinkit_dns.sh` (commit
  `775bcd4`) under the maintenance lock at 07:25. WARP was not restarted (PID
  20421) and every health tick passed. Backup:
  `/root/router-script/backup-f12`.
- At 07:27, removed the 20 leaked CloudFront routes once, deleting only
  addresses on the recorded list that were still unowned: all 20 went. The
  ownership check now finds only the two WARP endpoints. All 8 current Blinkit
  addresses remain routed on `eth0`.
- The new cleanup acts only on the next Blinkit record change; its log line
  ("replaced-address routes removed") has not appeared yet.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 15.4)
- `../../refresh_blinkit_dns.sh`

## 2026-10-22 — Final read-only validation; new finding F31 (fix not deployed)

- Ran a read-only check of the router at the user's request. Every check
  passed:
  - load 0.19, 279 MB RAM free, `/overlay` 16 %;
  - no kernel errors;
  - WAN up on a 119 h lease;
  - WARP on for both families: HTTPS 71–74 ms, 56.8 Mbps, 0 % loss;
  - DNS and all invariants intact;
  - 720 of 720 health checks passed in 6 h;
  - all deployed scripts and binaries match the repo.
- Benign: MediaTek Wi-Fi driver log noise, campus ICMP filtering beyond the
  gateway, transient cron zombies. The WARP client is CPU-bound at about
  60–70 Mbps.
- New finding F31: `tun0` is in no fw3 zone and `INPUT` accepts by default, so
  connections arriving over the tunnel reached SSH, the admin UI and DNS. The
  test-first fix (commit `3b3a183`) drops new inbound connections on `tun0`.
  Per the user, it is not deployed. See [[security/secrets-and-trust]].

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 16)
- `../../tunnel.sh`, `../../ensure_network.sh`

## 2026-10-22 — Deployed F31 and the pending doc files

- With the user's authorisation, promoted `tunnel.sh` and `ensure_network.sh`
  (F31, commit `3b3a183`) under the maintenance lock at 08:39. The next check
  added the IPv4 and IPv6 rules dropping new inbound connections on `tun0`,
  and the check after it added nothing. WARP was not restarted (PID 20421).
  Its tunnel traffic, DNS and LAN forwarding were verified unaffected.
- Also deployed `README.md` and `PROJECT_CONTEXT.md`, which carry the F25/F26
  documentation fixes. All 28 deploy-set files (everything except `.env` and
  `config.json`) now match the repo. Backup:
  `/root/router-script/backup-f31`.
- Correction: the previous entry's integrity figure should read 26 of 28 files,
  not 28 of 30.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 16.5)
- `../../tunnel.sh`, `../../ensure_network.sh`

## 2026-10-22 — Cleaned up the router and Mac project directories

- At the user's request, deleted the four deployment backups, then cleaned the
  router directory. Removed: 17 August rollback script copies, two old rollback
  binaries, six backup and staging folders, stale router copies of the Mac sync
  tools, a `.DS_Store`, and an old `.env` copy (deleted unread).
- Nothing live referenced these files. 27 of them were already in git; the
  other 27 are in a private archive on the Mac (`~/router-script-archive/`),
  verified byte-identical.
- The router directory now holds only the deploy set, the secrets, logs and
  diagnostics: 33.3 MB down to 21.2 MB, `/overlay` 16 % down to 11 %. Health
  checks kept passing, and WARP did not restart.
- On the Mac, removed `.DS_Store` and two `__pycache__` folders. Kept logs,
  diagnostics and the 3.3 GB Rust build cache.
- Rollback now uses git versions (report section 17.3). Seven wiki pages that
  described the removed copies as still on the router were updated.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 17)

## 2026-10-22 — Fixed three tunnel.sh start-path issues (F32–F34, not deployed)

- F32: every start deleted the campus and public `/32` exceptions before
  re-resolving them. On a reuse start that moved live traffic to WARP, and on
  any start a failed lookup lost its route. `tunnel.sh` now only adds routes,
  and the health check's refresher is the only remover.
- F33: the WAN gateway now comes from `eth0`'s own default route, not from the
  first default on any interface.
- F34: a failed optional host route now warns instead of aborting the WARP
  start under `set -e`.
- `tunnel.sh` is now exercised in the sandbox (six new tests). 89 tests pass
  under `sh` and `dash`. Not deployed; the steps are in the report's
  section 18.4.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 18)
- `../../tunnel.sh`, `../../tests/test_tunnel_start.py`

## 2026-10-22 — Deployed the tunnel.sh start-path fixes (F32–F34)

- With the user's authorisation, promoted the new `tunnel.sh` under the
  maintenance lock at 15:35. A read-only dry run on the router first
  confirmed the new gateway lookup and the resolution pipeline.
- A verification run through the reuse path exited 0, and no host route was
  removed (5 campus, 37 public, 45 metric-1 routes before and after). WARP
  kept its PID, and the next health check passed.
- The router's 28 deploy-set files match the repo. The previous `tunnel.sh` is
  in git (`49dfedd`).

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 18.5)

## 2026-10-22 — Housekeeping: page split, merged branches, archive

- Split `operations/health-recovery.md` (125 lines) by topic:
  - portal token login and stale-session recovery moved to the new
    [[operations/portal-login]];
  - the direct-WAN `/32` rules moved to the new [[systems/host-routes]];
  - the check list absorbed the clock and `tun0` side notes (85 lines now).

  The index lists both new pages, and three incident pages link to them. Fixed
  a relative link to [[flows/boot-and-recovery]].
- Deleted the merged `full-review-2026-10-20` and `tunnel-start-fixes`
  branches, and the off-router archive `~/router-script-archive` (the user is
  done with it).

## Sources

- [[operations/health-recovery]], [[operations/portal-login]], [[systems/host-routes]]

## 2026-10-22 — Fixed the open issues on a branch (not deployed)

- **WARP client** ([[systems/warp-client]]):
  - F35: a session whose TUN writes keep failing now ends.
  - F18: the key and certificate PEM files are deleted once loaded.
  - F17: backoff depends on how long the session was connected.
  - F16: a 90 s idle timeout, and the CONNECT stream's end is handled.
  - F36: the pipeline tests run against the production code.
  - F27: the dead `pending_pkt` is removed.
  - F10: opt-in `--tun-backpressure`, off by default.
  - F37: `--syslog`, so `logread -e usque-rs` shows why sessions end.
- **Scripts:**
  - F38: the fw3 include `firewall_hook.sh` restores the rules right after a
    firewall restart ([[flows/boot-and-recovery]]).
  - F39: `lock.sh` records the lock's owner, so a live owner is never displaced
    by age.
  - F40: `promote_staged.sh` checks a manifest, then promotes as one process
    ([[operations/deployment]]).
  - F42: PIPE traps, so an SSH drop still runs the cleanup.
  - F41: game mode no longer toggles `filter_aaaa`
    ([[bugs/known-issues]]).
  - A1: `defaults.sh` holds the shared defaults.
  - A2: isolation tests.
  - A9: a once-per-boot platform check.
  - `measure_load_latency.sh`.
- **Checks:**
  - 133 shell tests pass under `sh` and `dash`, and 76 + 4 Rust tests pass in
    the pinned image.
  - The lock, the promotion and the hangup cases also pass under BusyBox 1.33.1.
  - The candidate binary was built twice, byte-identical (sha256 `0d1496d3…`).
- **Deployment.** Not deployed; the steps are in the report's section 19.6.
  This first deployment must hold the lock with an ownerless `mkdir`, and game
  mode must be off.
- **Pages updated:**
  - [[systems/warp-client]], [[systems/script-map]], [[systems/dns]],
    [[systems/google-wan]];
  - [[operations/health-recovery]], [[operations/deployment]];
  - [[flows/boot-and-recovery]], [[security/secrets-and-trust]],
    [[bugs/known-issues]].

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 19)

## 2026-10-23 — Deployed the open-issues batch

- With the user's authorisation, promoted 21 scripts, the two docs and the
  six new files under an ownerless lock at 01:01:27, and registered the fw3
  include. The first check on the new code passed, including the new
  "Platform check passed.".
- Restarted WARP on the new binary (`0d1496d3…`) at 01:02:13. It was ready
  in 2 s, so WARP was down for about 4 s. `logread -e usque-rs` now shows the
  client's connection events.
- A `fw3 reload` ran the include. Its health check passed at 01:03:10, and
  every rule survived the reload.
- Blinkit answers have not changed since F13 began logging, so immediate route
  removal stays. Fourteen PEM files left in `/tmp` by earlier client stops
  confirm F18.
- All deploy-set files match the repo; the branch is merged into `main`. The
  loaded-latency measurement is still to do (report section 19.7).

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 19.9)

## 2026-10-23 — Measured loaded latency; F10 stays off

- At the user's request, ran `measure_load_latency.sh` three times on the
  default client and three times with `WARP_TUN_BACKPRESSURE=64`, then
  restored the default. Each switch restarted WARP (about 3 s each).
- With the campus uplink congested, an upload pushed round trips to 122–149 ms
  (peak 468 ms) at 10–18 Mbit/s. On a quiet uplink: 35 ms at 80 Mbit/s.
- Backpressure did not lower upload latency on the quiet uplink (39–58 ms) and
  cost 4–8 % of throughput. Counters show why: `tun0` dropped 51 packets at its
  ring, and its fq_codel never held a queue. F10 stays off.
- The tool's default download size (10 GB) is refused by the speed test; the
  runs used 75 MB. See [[systems/warp-client]].

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 19.10)

## 2026-10-23 — Fixed the latency tool's download phase (not deployed)

- `measure_load_latency.sh` now repeats a 75 MB download (the largest the
  speed test serves) until the phase ends.
- A refused or failed request ends the load and is logged as "no download
  (HTTP code)". Before, the 10 GB default was refused, the phase ran idle, and
  the log showed 0.0 Mbit/s.
- On branch `latency-tool-download-loop`; it needs a deploy of the one file.

## Sources

- `../../measure_load_latency.sh`, `../../tests/test_latency_tool.py`
- `../../audit/2026-10-20-full-review/REPORT.md` (section 19.10)

## 2026-10-25 — Upload CoDel for the WARP client (F10, second fix), not deployed

- At the user's request, bounded how long an upload datagram may wait in the
  client: `--upload-codel MS` applies CoDel (RFC 8289) to quiche's datagram
  queue. The client records when each datagram entered that FIFO, and drops
  the oldest once the queue has stayed above MS for 100 ms.
- `tunnel.sh` passes it when `WARP_UPLOAD_CODEL` is 1–999 and the binary lists
  it; it is off by default. `measure_load_latency.sh` names the client's
  upload-queue options in each run's log line.
- **Why CoDel:** a count limit is a delay limit at one rate only, and the
  uplink ran at 10–80 Mbit/s within an hour. A client-side queue in front of
  quiche would make quiche think the client is idle.
- **Checks:** 94 unit and 4 integration tests in the pinned image, eight
  mutations caught, fmt and strict Clippy clean; shell tests under `sh` and
  dash. The candidate binary was built twice, byte-identical (sha256
  `4c9cc33b…`); the same setup rebuilt `main`'s client as the deployed
  `0d1496d3…`.
- **Traps:** BusyBox's `grep -o` finds only one of two patterns, and
  `cargo clean -p` needs `--target` when `CARGO_BUILD_TARGET` is set.
- **Not deployed, not measured.** The report's section 20.5 has the plan: at a
  busy hour, alternate default and `WARP_UPLOAD_CODEL=20` runs, with a
  decision rule. It needs the user's permission.
- **Two attempts, 14:14 and 14:26 IST, with the user's permission:** each
  congestion check found the uplink quiet (57.3 and 72.7 Mbit/s up, 46 and
  34 ms median), so nothing was deployed (report section 20.7). The router's clock was 91 minutes slow, and
  `ntpd` had logged no sync since a reboot that morning.
- See [[systems/warp-client]] and [[bugs/known-issues]].

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 20)

## 2026-10-25 — Router clock 91 minutes slow after a reboot (audit, not fixed)

- After a reboot at about 08:28, the router's clock was 5,477 s behind, and
  NTP had not corrected it six hours later. Measured from the Mac against the
  router web server's `Date` header; no SSH.
- Likely cause (F43): `ntpd`'s only server, `time1.google.com`, resolves to
  its IPv6 address once WARP is up. `google_wan_policy.sh` rejects the
  router's own IPv6 traffic to Google, and BusyBox `ntpd` retries that
  address forever without logging. See [[systems/google-wan]].
- The campus does not block NTP: Google's servers answer the Mac over the
  direct path, with or without the DSCP marking `ntpd` uses.
- Side findings: F44 (the LAN→`tun0` ACCEPT shadows the LAN's Google IPv6
  rejection) and F45 (the clock warning misses most skews).
- Proposed: let the router's NTP through the IPv6 rejection (F43), and a
  log-only skew warning (F45). The read-only router checks and the fix wait
  for the user's approval.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 21)

## 2026-10-25 — Clock checks after the firmware upgrade to 4.11.0

- With the user's permission, ran the read-only checks in report section 21.9
  and two more read-only rounds. Nothing changed on the router.
- The user had upgraded the firmware to GL.iNet 4.11.0 at about 17:21. It
  replaces BusyBox `ntpd` with chrony (`chrony-nts` 4.1): six NTS sources,
  none of them Google's, with `makestep` and `nocerttimecheck`. The clock was
  within 1 ms.
- Confirmed on the router: there is no RTC. BusyBox resolves
  `time1.google.com` to its IPv6 address while WARP is up, and router-script's
  OUTPUT rejection refuses the send (F43's mechanism). The LAN→`tun0` ACCEPT
  sits above the FORWARD Google rejection (F44).
- GL.iNet's new network-quality pings `google.com` once a second; every ping
  goes to IPv6 and is refused.
- Revised proposal: drop the router's own (OUTPUT) Google IPv6 rejection
  (optional), fix F44's rule order, and add F45's skew warning. The UDP 123
  exemption is withdrawn. Awaiting the user's approval.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (sections 21.11–21.12)

## 2026-10-25 — Fixed F43–F45 on a branch (not deployed)

- With the user's approval, one commit each, test first:
  - F43: `google_wan_policy.sh` no longer rejects the router's own IPv6
    traffic to Google, which now goes through WARP. An upgrade removes the old
    OUTPUT rules.
  - F44: the LAN's Google IPv6 rejects are kept above the LAN→`tun0` ACCEPT.
    When they are out of order they are reinstalled on top, and that is
    logged.
  - F45: the health check warns when the clock and a direct probe's `Date`
    header differ by more than 120 s, checking every 10 minutes of uptime.
- 144 tests pass under macOS `sh` and `dash`, and the clock check also ran in
  BusyBox 1.33.1. A healthy tick starts 281 processes instead of 290.
- Not deployed; the deployment plan is in the report. See
  [[systems/google-wan]] and [[operations/health-recovery]].

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 21.13)

## 2026-10-25 — router-script checked against firmware 4.11.0 (audit, not fixed)

- With the user's permission, five read-only SSH rounds, each shown first.
  Nothing changed on the router.
- The upgrade removed `/root/router-script` but kept its crontab and fw3
  include. Nothing ran from 17:21 to 17:44, when it was redeployed from the
  Mac, and the older logs are lost (F46).
- On every `ifup`, GL.iNet's `99-disable_ipv6` hotplug turns IPv6 off on
  every interface while GL.iNet's own IPv6 switch is off. `main`'s LAN IPv6
  repair runs `ifup lan`, so it undoes itself, and each run costs a WARP
  restart (F47). See [[systems/ipv6]].
- Uncommitted edits, deployed at 17:56, stopped that loop. The router no
  longer matches `main`, and the edits fail 13 of the existing tests because
  the tests were not updated (F48).
- dnscrypt-proxy, the DoH fallback, now starts only under GL.iNet's own DNS
  settings, so it is not running (F49). See [[systems/dns]].
- Older than the upgrade: the Blinkit refresher's SIGHUP looks for
  dnsmasq's PID file in the wrong directory, so dnsmasq keeps serving
  replaced addresses until it restarts (F50).
- Also: `scp` from the Mac needs `-O` (F51), and the platform check passed
  while missing all of this (F52).
- Checked fine: every tool (`timeout` is now GNU's, `ip` iproute2 6.3), the
  cron pipeline, the include, the secret files' modes, router-script's rules
  without duplicates, and IPv4-only Blinkit answers from dnsmasq 2.92.
- Fixes await the user's approval.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 22)

## 2026-10-26 — Implemented firmware 4.11.0 fixes (F47, F48, F50–F52, not deployed)

- Merged `latency-tool-download-loop` (`0c110e9`) and committed the deployed
  LAN IPv6 runtime repair (`6d2e382`) with sandbox tests modelling GL.iNet's
  `99-disable_ipv6` hotplug hook (F47, F48).
- Fixed `refresh_blinkit_dns.sh` (`8c4da80`) to signal dnsmasq via
  `/var/run/dnsmasq/dnsmasq*.pid` (F50).
- Added `scp -O` (`73ec853`) to `sync_to_router.sh`, `sync_from_router.sh` and
  `download_emergency_diagnostics.sh` (F51).
- Extended `check_platform_once` (`2b550d2`) and `defaults.sh` (`DNSMASQ_PID_DIR`)
  to warn on GL.iNet's IPv6 hook while its switch is off, a stopped
  `dnscrypt-proxy`, and a missing dnsmasq PID file (F52).
- Updated [[systems/policy-routing]], [[systems/dns]], [[systems/ipv6]] and
  `configure_dns.sh`. All 145 tests pass under `sh` and `dash`.

## Sources

- `../../audit/2026-10-20-full-review/REPORT.md` (section 22.8)
- `../../ensure_network.sh`, `../../configure_lan_ipv6.sh`, `../../refresh_blinkit_dns.sh`
- `../../tests/test_lan_ipv6.py`, `../../tests/test_platform.py`, `../../tests/test_sync.py`

## 2026-10-26 — Consolidated CI/CD pipeline, upgrade survival, and wiki-llm docs

- Merged `claude/funny-chaplygin-b3e102` (F43–F45) with the firmware 4.11.0
  fixes (F47, F48, F50–F52).
- Added Linux/BusyBox `stat -c %Y` fallback for `date -r` in `lock.sh` and
  `ensure_network.sh`.
- Added `.github/workflows/ci.yml` at the repository root to run POSIX/dash
  syntax checks, ShellCheck, all Python sandbox tests, and Rust `fmt`, `clippy`,
  and unit/pipeline tests.
- Added `update_from_git.sh` (scheduled every 15 minutes in cron) to poll the
  configured `deploy` branch on GitHub, verify CI check-runs succeeded, promote
  under `lock.sh`, gate on `ensure_network.sh`, and roll back automatically on
  failure.
- Updated `bootstrap_router.sh` and `check_platform_once` to register and check
  `/root/router-script/` and `/etc/router-script/` in `/etc/sysupgrade.conf` so
  firmware upgrades preserve the router setup (F46).
- Consolidated all stray markdown and audit files (`PROJECT_CONTEXT.md`,
  `CHANGES_EXPLAINED.md`, `.claude/plan.md`, `usque-rs-optimized/README.md`,
  `usque-rs-optimized/SETUP_NOTES.md`, and `audit/`) into `wiki-llm/raw/sources/`
  and synthesized [[bugs/full-review-2026-10-20]], leaving only a concise
  root `README.md` and `usque-rs-optimized/LICENSE.md` outside `wiki-llm/`.

## Sources

- `../../.github/workflows/ci.yml`, `../../update_from_git.sh`, `../../bootstrap_router.sh`
- `../../tests/test_updater.py`, `../../tests/test_platform.py`
- [[bugs/full-review-2026-10-20]], [[operations/deployment]], [[sources]]

## 2026-10-26 — Merged F10 upload CoDel, pushed to GitHub, and deployed to router

- Merged `claude/mystifying-sutherland-2fc664` (`ca4f75e`, F10 opt-in
  `--upload-codel MS` binary and scripts) into `main` and `deploy`, removed all
  remaining worktrees/branches, and pushed `main` and `deploy` to
  `git@github.com:athcodes2005/router-script.git`.
- Deployed `main` to `root@192.168.8.1:/root/router-script` via
  `sync_to_router.sh`, registered `/root/router-script/` and
  `/etc/router-script/` in `/etc/sysupgrade.conf` (F46), installed the updated
  cron pipeline (with 15-minute `update_from_git.sh`), and removed the retired
  root `PROJECT_CONTEXT.md`.
- Verified live: `usque-rs` connected (`warp=on` on both IPv4 and IPv6), IPv6
  `OUTPUT` Google rejects removed (`0`, F43), LAN Google IPv6 rejects placed at
  the top of `FORWARD` above the `LAN→tun0` ACCEPT (F44), F45 clock check silent,
  and F52 platform check accurately naming the 4.11.0 `99-disable_ipv6` hook and
  `dnscrypt-proxy` state while `dnsmasq`'s PID file and `/etc/sysupgrade.conf`
  passed.

## Sources

- `../../sync_to_router.sh`, `../../update_from_git.sh`, `../../ensure_network.sh`
- Live router verification on 2026-10-26 00:36 IST.

## 2026-10-26 — Split `usque-rs` into `athcodes2005/usque-rs-openwrt` and wired `fetch_usque_rs.sh`

- Split the Rust client source and its internal `wiki-llm/` into the public fork
  `https://github.com/athcodes2005/usque-rs-openwrt`
  (`/Users/atharva/projects/usque-rs-openwrt`), with `upstream` tracking
  `Diniboy1123/usque-rs` and GitHub Releases publishing verified static
  `aarch64-unknown-linux-musl` assets on `v*.*.*` tags and the `release` branch.
- Removed `usque-rs-optimized/` and tracked binaries from `router-script`.
- Added `fetch_usque_rs.sh` (invoked by `update_from_git.sh` and
  `sync_to_router.sh`) to fetch, SHA-256 verify, back up (`usque-rs-upstream-v0.1.0`),
  promote under `lock.sh`, and health-gate new `usque-rs` binary releases with
  automatic rollback.

## Sources

- `../../fetch_usque_rs.sh`, `../../update_from_git.sh`, `../../defaults.sh`
- `../../tests/test_updater.py`, [[systems/warp-client]], [[sources]]

## 2026-10-26 — Encrypted DoT/DoH primary via `dnsproxy` (replacing `dnscrypt-proxy2`)

- Benchmarked DoT and DoH resolvers on the router: Cloudflare DoT/DoH (`1.1.1.1`,
  `1.0.0.1`) and Quad9 DoT (`9.9.9.9`) answered in ~20 ms over warm connections.
- Promoted `127.0.0.1#5453` (`dnsproxy` in parallel upstream mode across
  Cloudflare DoT/DoH and Quad9 DoT/DoH) to primary (`DNS_SERVERS="127.0.0.1#5453 8.8.8.8 8.8.4.4 10.200.1.11"`).
- Commented out the legacy `dnscrypt-proxy2` code across `defaults.sh`,
  `configure_dns.sh`, `ensure_network.sh`, `dns_flow.sh`, and `diagnose.sh` with
  notes that `dnscrypt-proxy2` was replaced by `dnsproxy` on firmware 4.11.0+.
- Updated [[systems/dns]], [[systems/script-map]], [[operations/health-recovery]],
  and [[bugs/known-issues]].

## Sources

- `../../defaults.sh`, `../../configure_dns.sh`, `../../ensure_network.sh`
- `../../dns_flow.sh`, `../../diagnose.sh`, [[systems/dns]]

## 2026-10-26 — Raised `tun0` MTU to 1,320 B and aligned TCP MSS to 1280/1260 (`usque-rs` `v0.2.0`)

- Added `TUN_MTU=1320`, `TUN_IPV4_MSS=1280` (`1320 - 40`), and `TUN_IPV6_MSS=1260`
  (`1320 - 60`) in `defaults.sh` to match `usque-rs` `v0.2.0`'s 1,320 B dynamic
  datagram IP payload ceiling (`[I4]`).
- Updated `tunnel.sh` to pass `--mtu "$TUN_MTU"` on launch and apply
  `ip link set dev "$TUN_IF" mtu "$TUN_MTU"` on reuse; updated `ensure_network.sh`
  (`nat_rules_ok`, `ensure_nat_and_mss_rules`) and `stop_tunnel.sh` to verify,
  repair, and clean up `tun0` MTU and `1280`/`1260` MSS rules in place.
- All 169 Python sandbox and unit tests pass.
- Deployed `edb40fc` and `usque-rs` `v0.2.0` (`83deac89…`) to the router and
  verified live:
  - `ip link show dev tun0` reports `mtu 1320`.
  - `iptables`/`ip6tables -t mangle -S FORWARD` clamp `tun0` ingress SYNs to
    `1280` (IPv4) and `1260` (IPv6).
  - 1,320 B packets (`ping -4 -s 1292 -I tun0 1.1.1.1 -c 3`) pass with 0% loss
    (3.58–4.78 ms RTT).
  - `measure_load_latency.sh 12` recorded **4/5/6 ms** idle RTT, **93.6 Mbit/s
    upload** (27/46/67 ms RTT), and **136.9 Mbit/s download** (8/23/54 ms RTT).

## Sources

- `../../defaults.sh`, `../../tunnel.sh`, `../../stop_tunnel.sh`, `../../ensure_network.sh`
- `../../tests/test_defaults.py`, `../../tests/test_network_recovery.py`, `../../tests/test_tunnel_start.py`
- [[systems/warp-client]], [[bugs/opencode-pqc-mss-clamping-2026-10-08]]

## 2026-10-26 — Rolled out `usque-rs` `v0.2.1` (`sendmmsg` batching & sub-ms pacing coalescing)

- Fixed a missing `libc` target dependency and `musl` `MSG_DONTWAIT` flag cast
  (`756ec94`) in `athcodes2005/usque-rs-openwrt` so `v0.2.1` built cleanly across
  all 6 `musl` targets.
- Ran `fetch_usque_rs.sh --download-only` on the Mac and `fetch_usque_rs.sh` on
  the router: verified archive SHA-256 `7e8e54a2…`, backed up `v0.2.0`
  (`83deac89…`) to `usque-rs-upstream-v0.1.0`, promoted `v0.2.1` (`77eb75c4…`,
  PID `22792`) with `--mtu 1320 --congestion-control bbr2`, and passed the
  health check.
- `measure_load_latency.sh 12` on `v0.2.1` recorded:
  - **Idle:** `min/median/max = 5/5/6 ms` (12 samples, 0 failed)
  - **Upload:** `min/median/max = 13/19/28 ms` at **133.3 Mbit/s** (upload
    throughput +42% over `v0.2.0`'s 93.6 Mbit/s while cutting loaded upload
    median RTT from 46 ms to **19 ms**)
  - **Download:** `min/median/max = 5/5/14 ms` at **90.3 Mbit/s** (loaded
    download median RTT equal to 5 ms idle!).

## Sources

- `../../fetch_usque_rs.sh`, `../../measure_load_latency.sh`, [[systems/warp-client]]

## 2026-10-26 — Validation audit of router-script and usque-rs-openwrt

- Read-only audit of both repos against this wiki (report:
  `raw/sources/audit/2026-10-26-validation/REPORT.md`). Baseline: 169 tests,
  `cargo test` and clippy green; deployed `usque-rs` (`77eb75c4…`) matches the
  v0.2.1 release; MTU/MSS/DNS settings consistent across code and wiki.
- Fixed on branch `validation-2026-10-26` (not yet deployed or merged):
  - B1: `USQUE_RELEASE_TAG` defaults to `v0.2.1`; a new usque-rs release no
    longer auto-deploys through the 15-minute updater.
  - B2/B7: a release or commit that fails its health check is recorded
    (`.usque_failed_sha`, `.git_failed_commit`) and skipped until it changes or
    `--retry-failed` is passed.
  - B3: rollback slot renamed `usque-rs.prev`, router-local and never shipped;
    falls back to legacy `usque-rs-upstream-v0.1.0` (which held v0.2.0 on the
    router, but v0.1.0 on the Mac).
  - B4: test keeps `update_from_git.sh` and `sync_to_router.sh` file lists equal.
  - A2/A4: a failed dnsproxy restart no longer aborts `configure_dns.sh`;
    `ensure_network.sh` restarts a dead dnsproxy once per tick. A1: dnsproxy
    runs in its default upstream mode (wiki corrected; not "parallel").
  - A5 `game_mode.sh` status re-exec, A6 `.env` before `paths.sh` in rotate
    scripts, A7 `latency.log` rotation.
  - D1–D3, A10: dead Sources paths repointed, README notes the usque-rs split,
    index and host-route wording corrected.
- This log has historical ordering quirks (2026-09-19 entries after 2026-09-22,
  a mid-file maintenance section); left as is because the log is append-only.
- usque-rs-openwrt branch `fix-validation-2026-10-26` (not pushed): release
  workflow gated on tests and tag/version match; `warp-svc`-derived evidence and
  local details removed from the public tree (history unchanged).

## Sources

- `../raw/sources/audit/2026-10-26-validation/REPORT.md`
- `../../fetch_usque_rs.sh`, `../../update_from_git.sh`, `../../configure_dns.sh`, `../../ensure_network.sh`
- [[bugs/known-issues]], [[operations/deployment]]

## 2026-10-26 — Deployed validation fixes (`336e7f5`)

- Read-only pre-check: every deployed file matched `main` (`0225890`), the
  binary was v0.2.1, `.env`/`config.json`/`blocked_sites.txt` matched the Mac by
  hash, and the legacy rollback slot held v0.2.0 (`83deac89…`).
- Shipped only the 32 code files (no `.env`, `config.json`, `blocked_sites.txt`
  or binary) through the staged manifest and `promote_staged.sh`, wrote
  `.deployed_commit`, and ran a health tick: hashes matched, WARP restarted,
  default route on `tun0`, Cloudflare trace `warp=on`.
- `main` and `deploy` now point at `336e7f5`. GitHub Actions has never run for
  this repository (0 runs), so `update_from_git.sh`'s CI gate would block
  any git-driven update; the maintenance log shows no updater activity.

## Sources

- `../../sync_to_router.sh`, `../../promote_staged.sh`, `../../update_from_git.sh`
- [[operations/deployment]]

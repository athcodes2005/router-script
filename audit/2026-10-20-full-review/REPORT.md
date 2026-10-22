# Full review of router-script — 20 October 2026

**Status: Phase 2 complete for the approved batches 1–3, and deployed to the
router on 2026-10-20 at 21:16 (step A) and 21:19 (step B) IST; see §13.**
Eleven findings are fixed (F01, F02, F03, F04, F05, F06, F07 log-only, F08,
F09, F11, F15), one commit each, on branch `full-review-2026-10-20`. The
baseline is `2ba81fe` on `main`; `.env`, `config.json`, `logs/`,
`diagnostics/` and Cargo `target/` are excluded by `.gitignore`.

- **Outcome per finding:** §8.
- **Measured effect:** §9.
- **Invariant re-check:** §10.
- **Deployment checklist and rollback:** §11.
- **What I could not verify:** §12 (partly superseded by §13).
- **Deployment record:** §13.

Sections 0–7 are the Phase 1 audit exactly as committed in `8be33c1`.

## 0. Scope, method and limits

**Read:** `README.md`, `PROJECT_CONTEXT.md`, every `wiki-llm/` page, all prior
audits (`2026-09-19`, both Blinkit audits, `2026-09-23-google`,
`2026-10-08-mss-clamping`), all 23 shell scripts, `tools/`, `tests/`, and all
Rust sources in `usque-rs-optimized/src`.

**Ran locally (no router access, by rule):**

- The existing 21 unit tests pass under macOS `/bin/sh` (bash 3.2 in POSIX mode)
  and under `dash` (the closest available relative of BusyBox ash).
- `sh -n` and `dash -n` are clean on all 23 scripts.
- A throwaway **sandbox** (in my scratchpad, not the repo): copies of the scripts
  run under `dash` with `PATH` limited to logging stubs. Absolute paths (`/etc`,
  `/sys`, `/proc`, `/tmp`) are rewritten into a fake root, and `.env`,
  `config.json` and the binaries are not copied. I used it to **count process
  executions per health tick** and to **reproduce F02, F04, F08 and F09**.
- Statistics on the 2026-08-19 game-monitor CSVs.

**Limits that matter for how much you should trust this:**

- Local `logs/` and `diagnostics/` are from the **last pull on 2026-08-01**. They
  predate the Aug 7 to Oct 8 fixes, so I use them for failure-mode frequencies
  and platform facts, not as proof of current behaviour.
- `shellcheck` and `pytest` are not installed (I did not download anything).
  The tests are `unittest` classes, which pytest can also run.
- Rust: `cargo test --offline` fails natively (crates were only ever built inside
  the cross/Docker image) and OrbStack/Docker is not running. **No Rust claim
  here was compiled or executed.**
- BusyBox ash semantics were approximated with dash, not tested directly.
- Secrets: `.env` and `config.json` were never opened. Anything secret-like in
  logs or diagnostics was counted or masked, never printed.

## 1. Architecture as I understand it

### 1.1 Data plane

| Traffic | Mechanism |
|---|---|
| Public IPv4 from LAN | `main` default `dev tun0 metric 5` beats netifd's WAN default (`metric 10`, set by GL.iNet's multi-WAN defaults). It is masqueraded on `tun0` and carried by `usque-rs` (CONNECT-IP over QUIC/HTTP-3) to Cloudflare. |
| Public IPv6 from LAN | Clients get ULA `fd63:3b28:d1ea::/64` from odhcpd (`ra_default=2`). Default `dev tun0 metric 5`, then NAT66 on `tun0`. |
| WARP transport itself | `/32` routes via the WAN gateway for 162.159.198.1, 162.159.192.1 and `config.json`'s `endpoint_v4`, so QUIC never enters `tun0`. |
| Campus | `10.0.0.0/8` and `103.21.124.0/22` via WAN gateway `metric 1`. DNS-derived `/32`s for 5 split-horizon names (`CAMPUS_DIRECT_DOMAINS`). |
| Selected apps | DNS-derived `/32`s via WAN for 11 names (Blinkit, Sentry, Gemini, Supercell). Blinkit names also get IPv4-only local DNS records. |
| Google / YouTube | ipsets `google_net4/6` (402 published prefixes) plus `google_dns4/6` (learned by dnsmasq). IPv4 is marked `0x100000`, then rule 710 sends it to table 102 (WAN default). Google IPv6 is rejected (TCP RST or ICMPv6) in `FORWARD -i br-lan` **and `OUTPUT`**. 8.8.8.8 and 8.8.4.4 are in the set, so DNS upstreams use the WAN even when WARP is dead. |
| Game sessions | NEW TCP/UDP to port 9339 from `br-lan` is marked `0x40000/0xf0000` (saved to connmark). Rule 700 sends it to table 101 (WAN default). Conntrack-derived `/32`s are a fallback. |
| Router sockets bound to `tun0` | Rule 690 `oif tun0 lookup main`, so health probes test WARP even for Google destinations. |
| GL.iNet's own rules (not in the wiki) | Priorities 1–9920 run after ours, including `9920: from all iif br-lan blackhole`. LAN traffic reaches `main` only via GL's `0x8000/0xf000` mark (rule 6000). This is inferred from the 2026-08-01 snapshot. |
| Filter | `FORWARD` policy is **DROP** and fw3 chains end in `reject`. LAN↔`tun0` traffic is admitted only by four rules `tunnel.sh` inserts. In the 08-01 snapshot those rules had carried 9,031/18,185 IPv4 and 801/732 IPv6 packets. |
| TCP MSS | `-o tun0` uses clamp-to-PMTU; `-i tun0` uses `--set-mss 1240` (IPv4) and `1220` (IPv6). |

### 1.2 DNS

dnsmasq runs with `noresolv` and strict order:
`8.8.8.8 → 8.8.4.4 → 10.200.1.11 → 127.0.0.1#5453` (dnscrypt DoH, IPv6 not blocked).

- Seven campus names are forwarded to `10.200.1.11`.
- The portal and SSO names are pinned with `address=`. `login.sh` also pins them
  with curl `--resolve`.
- The three Blinkit names are local zones served from
  `/etc/router-script/blinkit-hosts/hosts`, IPv4 only.
- The 79 names in `google_domains.txt` feed the Google ipsets.

### 1.3 Control plane

- cron runs `ensure_network.sh` at :00 and :30, `collect_diagnostics.sh` every
  6 h, and `rotate_logs.sh` every 6 h.
- The maintenance lock is a directory on **flash**
  (`$DIR/.ensure_network.lock`). Health runs write an owner PID into it;
  `sync_to_router.sh`, `game_mode.sh` and `rotate_tunnel_ip.sh` take it
  without an owner.
- Cooldown and marker files live in `/tmp`.
- After a reboot, cron alone brings everything back. `bootstrap_router.sh` is
  a manual one-shot.

### 1.4 `ensure_network.sh` decision flow (one tick)

1. **Lock.** `mkdir` the lock. If it exists, skip the tick when the owner PID is
   alive with an `ensure_network.sh` command line. If the recorded owner is dead,
   take the lock at once. An ownerless lock is taken only when older than 180 s.
2. **Google policy.** `google_wan_policy.sh` refreshes sets, table 102, rules
   690/710, marks and IPv6 rejects. Failure is logged only.
3. **Storage.** If `/overlay` is ≥ 90 % full, run `rotate_logs.sh`.
4. **Wi-Fi config.** Check UCI country/htmode. On drift run `configure_wifi.sh`
   and re-check; if still bad, take a diagnostic and **exit 1**.
5. **Wi-Fi runtime.** If `ubus` reports a radio down, run `wifi reload`, wait
   5 s and re-check; if still down, take a diagnostic and **exit 1**.
6. **DNS config.** Checks: Google `check-dns`, strictorder, noresolv, the four
   upstreams present, the campus forwards, the Blinkit zones and addn-hosts,
   the portal/SSO pins, and the dnscrypt TOML. On drift run `configure_dns.sh`
   (which restarts dnscrypt-proxy and dnsmasq); if still bad, take a diagnostic
   and **exit 1**.
7. **DNS runtime.** dnsmasq must be running and resolve the pinned
   `internet.iitb.ac.in` to `10.x` within 8 s. Otherwise run `configure_dns.sh`
   and re-check; if still bad, take a diagnostic and **exit 1**.
8. **LAN IPv6.** If healthy, clear the cooldown. During the cooldown, log and
   continue. Otherwise run `configure_lan_ipv6.sh` (restarts dnsmasq and odhcpd,
   `ifup lan`). If that fails, take one diagnostic, start a 5-minute cooldown
   and **continue**.
9. **WAN lease and carrier.** If either is missing, run `recover_wan`:
   `stop_tunnel.sh`, `ifdown wan`, `ifup wan`, sleep 10. If still missing,
   take a diagnostic and **exit 1**.
10. **Campus core route.** `ip route get 10.200.1.11` must use `eth0`.
    Otherwise run `recover_wan`; if still wrong, take a diagnostic and
    **exit 1**.
11. **Interactive-login marker.** If direct IPv4 is down and the marker is
    under 5 minutes old, stop WARP and **exit 0**. If older, delete it and
    retry the token.
12. **Direct IPv4** (curl `--interface eth0`, two URLs, 2 s/4 s bounds). On
    failure wait 2 s and retry. On a second failure run `login.sh`, which does
    the token login and handles stale sessions. If `login.sh` wrote the
    marker, stop WARP and **exit 0**.
13. **Still down.** If WARP is running, stop it, run `login.sh` again and
    re-check. If still down, take a diagnostic and **exit 1**.
14. **`/tmp` pressure.** At ≥ 90 %, take a diagnostic, stop WARP, set the
    5-minute WARP cooldown and **exit 1**.
15. **Blinkit.** `refresh_blinkit_dns.sh` (non-fatal).
16. **Game mode.** If the marker is set, only direct IPv4 and portal login are
    checked, then **exit**.
17. **`tunnel_healthy_confirmed`.** Checks, in order: process, `tun0`, ready
    marker, IPv4/IPv6 defaults *contain* `tun0`, campus route, NAT and MSS
    (repaired in place), then an IPv4 HTTP probe bound to `tun0`. A live
    process gets one re-check after 3 s. If healthy, run
    `refresh_optional_routes` (game policy, campus, public and game `/32`s),
    clear the cooldown and **exit 0**.
18. **Cooldown.** If the tunnel is unhealthy and the cooldown is active, stop
    WARP so direct IPv4 is used, and **exit 0**.
19. **Restart.** Run `stop_tunnel.sh`, `tunnel.sh` (waits ≤ 25 s for the
    CONNECT-IP ready marker), sleep 10, restart odhcpd, then re-check
    (confirmed). If it fails, take a diagnostic, stop WARP, set a 5-minute
    cooldown and **exit 1**. If it passes, refresh the optional routes and
    **exit 0**.

### 1.5 `usque-rs` session lifecycle

1. Create `tun0`, then connect immediately.
2. QUIC handshake (≤ 15 s), then check the peer's SPKI against the pin.
3. HTTP-3 extended CONNECT `cf-connect-ip` (≤ 15 s), then write the ready
   file.
4. The established loop selects on TUN read, UDP recv, the quiche timer
   (minimum 5 ms), cooperative continuation, and paced-send deadlines. Every
   stage is capped at 64 items per pass, and a keepalive goes out every 30 s.
5. When the session ends, the ready file is removed and the client reconnects
   with 1–30 s backoff (reset to 1 s after a session that reached ready).

## 2. What the evidence shows

- **Log window:** `ensure.log*` covers 2026-04-30 to 05-02 and 07-26 to 08-01,
  11,571 runs at the old once-a-minute cadence. Typical days had **1–9 WARP
  restarts**. 2026-08-01 had **231** (the `/tmp` exhaustion incident, already
  fixed). Overall: 252 portal recoveries; 198 runs where internet stayed down
  after the tunnel teardown.
- **WAN cycling changes the WAN address.** On 08-01, three `recover_wan` cycles
  at 19:29, 19:30 and 19:31 got `10.1.39.184`, `.185` and `.186` respectively.
  None fixed the campus-route condition. A tunnel restart at 19:32 did.
- **Diagnostics flood during outages.** On 08-01, 21 snapshots were taken
  between 17:27 and 18:05 (51–79 KB each). **All 24 retained `diagnostic_*`
  files are from that one afternoon.**
- **The clock is wrong after boot.** After being off from about 05-02 to
  07-26, the router booted with its clock at 2026-05-01 (86 days behind).
  The next corrected run logged `Stale lock detected (age: 7445640s)`.
- **Health runs don't cause the latency spikes** (2026-08-19 monitor,
  825 router / 1,188 Mac samples). Inside the :00–:11 and :30–:41 windows,
  the router's WARP probe had median 82.4 ms and p90 91.7 ms; outside them,
  81.7 ms and 88.2 ms. The spikes in that dataset sit on the **Wi-Fi hop**:
  Mac→gateway p90 was 32–57 ms, against about 1 ms from router to WAN gateway.
  This data predates the 2026-09-22 game-policy code (see F08).
- **Measured per healthy tick (sandbox):** about **457 process executions**.
  Google `check-dns` accounts for 165 (36 %), the main Google policy 38,
  Blinkit 20, and the rest of the health check about 234. At 2 ticks a minute
  that is about 0.9 k per minute, or 1.3 M per day. This is an upper bound;
  BusyBox NOFORK/NOEXEC applets avoid some exec cost.
- **Persistent unrepairable DNS drift (sandbox):** every tick does 1 dnsmasq
  restart, 1 dnscrypt-proxy restart, 1 `/etc/config/dhcp` commit to flash and
  1 diagnostic, and exits **without ever running `login.sh` or the WARP
  logic**.

## 3. Findings

Severity reflects user-visible impact on this router. Confidence:
**Confirmed** means traced and/or reproduced; **Likely** means the mechanism is
confirmed but the trigger or impact is not observed; **Speculative** means
plausible but unproven.

| ID | Sev | Confidence | Category | Location | Finding |
|---|---|---|---|---|---|
| F01 | **High** | Confirmed | Security | `diagnose.sh:81`, `collect_diagnostics.sh:16,29` | Both Wi-Fi WPA2 passphrases are written into every diagnostic snapshot |
| F02 | **High** | Confirmed (sandbox) | Failure handling | `ensure_network.sh:488-527`, `:170` | A persistent Wi-Fi/DNS-stage failure blocks all WAN/portal/WARP recovery and repeats disruptive repairs every tick |
| F03 | **High** | Likely | Correctness | `ensure_network.sh:389-405`; `tunnel.sh:266-267,277-278` | LAN↔`tun0` FORWARD ACCEPT rules are never verified or repaired; router-side probes cannot see their loss |
| F04 | Medium | Confirmed (sandbox + logs) | Failure handling | `ensure_network.sh:557-566`, `:161-167` | A wrong campus route is "repaired" by cycling the WAN (new IP, all flows reset) instead of re-adding the route |
| F05 | Medium | Confirmed | Security | `login.sh:111` | IITB access token is passed on curl's command line |
| F06 | Medium | Confirmed (logs) | Resource / observability | 10 call sites in `ensure_network.sh`; `collect_diagnostics.sh:33-37` | Persistent failures take a full snapshot every tick; retention evicts onset evidence within about an hour |
| F07 | Medium | Confirmed code, Likely trigger | Correctness | `ensure_network.sh:251-254`; `game_mode.sh:130` | The check confirms a `tun0` default *exists*, not that it *wins*; WAN metric 10 is an unasserted dependency |
| F08 | Medium | Confirmed (sandbox), Likely impact | Concurrency | `ensure_network.sh:304-328` | Game-session policy (chain, PREROUTING jump, rule 700) is torn down and rebuilt on every healthy tick |
| F09 | Medium | Confirmed (sandbox) | Correctness | `rotate_tunnel_ip.sh:84-87` | WARP rotation always rolls back: the IPv6 probe hits Google (rejected) and the IPv4 probe bypasses WARP |
| F10 | Medium | Likely | Performance (Rust) | `tunnel.rs:240,528-546` | A 1,000-datagram unmanaged FIFO inside `usque-rs` can add hundreds of ms of latency during uploads |
| F11 | Low | Confirmed (measured) | Resource | `google_wan_policy.sh:35-42` | `check-dns` costs 165 process execs per tick (36 % of a healthy tick) |
| F12 | Low | Confirmed | Correctness | `refresh_blinkit_dns.sh:34-37` | Blinkit `/32` routes are never removed (§14 wrongly called this mostly harmless; **confirmed live and fixed in §15**) |
| F13 | Low | Likely | Resource | `refresh_blinkit_dns.sh:49-54` | Every Blinkit address change SIGHUPs dnsmasq, flushing its whole cache; the change rate is not logged |
| F14 | Low | Confirmed (history) | Observability | `ensure_network.sh:137-143` | Slow-tunnel detection (the 08-09 safety net) was removed on 09-19; a reachable-but-slow tunnel passes |
| F15 | Low | Confirmed | Observability | `diagnose.sh:157`; `ensure_network.sh:145-151` | The diagnostic WARP-IPv6 probe targets Google and has always failed since 09-23; `tunnel_internet_v6_ok` is dead code |
| F16 | Low | Likely | Liveness (Rust) | `tunnel.rs:230,592-599,622-634` | No client-side dead-peer timeout; the CONNECT stream closing is ignored |
| F17 | Low | Confirmed | Robustness (Rust) | `tunnel.rs:181-185` | A clean session close reconnects with zero delay |
| F18 | Low | Likely | Secret hygiene (Rust) | `tls.rs:43-49`; `tunnel.rs:214` | Private-key PEM temp files live for the whole session and are left in `/tmp` after SIGTERM/SIGKILL |
| F19 | Low | Confirmed | Concurrency | `game_mode.sh:47-49`; `rotate_tunnel_ip.sh:53-55` | No SIGHUP trap: an SSH drop leaves an ownerless lock and partial state |
| F20 | Low | Confirmed (trace) | Concurrency | `ensure_network.sh:368-376` vs `:262-302` | Overlapping `/32` ownership: the game refresher can delete a route the public refresher needs |
| F21 | Low | Speculative (skew is Confirmed) | Failure handling | `ensure_network.sh:97`; `login.sh:102-114`; `tls.rs:34-35` | Post-reboot clock skew can defeat ownerless-lock ageing and TLS validity checks |
| F22 | Low | Confirmed | Correctness | `ensure_network.sh:176-184` | DNS check ignores upstream order and extra zone forwards (invariant not enforced) |
| F23 | Low | Likely | Deployment | `sync_to_router.sh:85,99-108` | No `sync` after promotion; local secrets are pushed with no staleness check |
| F24 | Low | Speculative | Interoperability | `ensure_network.sh:37-38`; `tunnel.sh:40-41` | Game mark mask `0xf0000` overlaps GL.iNet's `0xc0000` policy-routing bits |
| F25 | Low | Unverifiable | Deployment | `sync_to_router.sh:85`; `README.md:135-145` | Rollback binary is not in the deploy manifest; its presence on the router is unverified |
| F26 | Nit | Confirmed | Docs | `README.md:19-21`; `PROJECT_CONTEXT.md:15`; wiki | Documentation drift |
| F27 | Nit | Confirmed | Dead code / cost | `stop_tunnel.sh:75-91`; `tunnel.rs:160,481-492` | Legacy cleanup forks; GNU `\s` in BusyBox BRE; dead `pending_pkt` |
| F28 | Nit | Confirmed | Observability | `ensure_network.sh:469,520` | Misleading log text |
| F29 | Nit | Confirmed | Maintainability | `ensure_network.sh:351`; `game_mode.sh:130` | Hard-coded LAN prefix and WAN metric |
| F30 | Nit | Confirmed | Resource | `tunnel.sh:286`; `ensure_network.sh:670` | odhcpd is restarted twice per WARP restart |

### F01 — Wi-Fi passphrases in every diagnostic (High, Confirmed)

- **What is wrong:** `diagnose.sh` runs `ubus call network.wireless status`.
  netifd includes each interface's `config`, and that includes `"key"`.
  `collect_diagnostics.sh` writes the output to flash with the default umask.
- **Trigger:** every 6-hourly snapshot, every failure snapshot, and every
  emergency download. `sync_from_router.sh` copies them to the Mac.
- **Evidence:** `diagnostics/emergency_20260801_193611_8846.log` lines 133 and
  175: `"encryption": "psk2", "key": <10 chars>` for both SSIDs. I printed
  masked values only. The local copy is mode `0644`. The router copy is
  probably 0644 too (cron umask; not verified). This contradicts
  `wiki-llm/wiki/security/secrets-and-trust.md`, which says the key stays
  router-local at mode 0600.
- **Fix:** pipe that `ubus` output through a redaction `sed` for
  `key|password|sae_password|auth_secret|acct_secret|priv_key|psk` values.
  Set `umask 077` in `collect_diagnostics.sh`.
- **Risk:** none to connectivity. **Invariants:** none.
- **Test:** a stub `ubus` that emits a key → the output contains `<redacted>`
  and not the secret; the snapshot file mode is 0600.
- **Your action (not mine):** consider deleting or redacting existing snapshots
  on the router and the Mac, and changing the Wi-Fi passphrase if any were
  shared.

### F02 — Wi-Fi/DNS stage failure halts all recovery (High, Confirmed)

- **What is wrong:** steps 4–7 `exit 1` on a persistent failure, with no
  cooldown. Every tick repeats the disruptive repair: `wifi reload` (both
  radios bounce) or `configure_dns.sh` (dnscrypt-proxy and dnsmasq restart,
  plus a UCI commit). Every tick also takes a full diagnostic, and never
  reaches WAN, portal or WARP recovery. Google's `check-dns` sits inside the
  DNS gate (`:170`), so an optional Google problem is treated as a fatal DNS
  fault. That contradicts the design note "policy failure must never restart
  WARP". This is the same class as the 2026-08-13 LAN-IPv6 repair loop, which
  was fixed only for IPv6.
- **Triggers:**
  - A firmware update renames `mt798111`/`mt798112`, so `configure_wifi.sh`
    exits "not a configured Wi-Fi device".
  - A radio that will not come up.
  - Overlay full, so `uci commit` fails.
  - `ipset` missing, or `google_domains.txt` missing after a partial deploy.

  Any of these, **combined with a portal logout**, leaves you with no internet
  until you intervene by hand.
- **Evidence (sandbox, 3 ticks):** each tick did 1 dnsmasq restart, 1
  dnscrypt-proxy restart, 1 UCI commit and 1 diagnostic, ran `login.sh` 0
  times, and ran the WARP logic 0 times, even though direct internet was
  marked down.
- **Fix:**
  1. Per-stage cooldown markers for the Wi-Fi reload and DNS reconfigure,
     reusing the LAN-IPv6 pattern.
  2. After a Wi-Fi stage failure, *continue*. WAN, portal and WARP don't
     depend on the radios.
  3. On DNS *config* drift with healthy DNS *runtime*, continue.
  4. Exit only when DNS *runtime* is down. Probe-driven actions would
     otherwise misfire there; for example, `login.sh` could log out a healthy
     portal session.
  5. Move `check-dns` out of the DNS gate and into the non-fatal Google stage.
- **Risk:** moderate, because it changes control flow in the watchdog.
- **Invariants:** "bounded recovery" is strengthened (adds cooldowns);
  nothing is relaxed.
- **Test:** whole-pipeline sandbox tests, each failing first:
  - DNS-config drift plus portal down → `login.sh` runs.
  - A persistent Wi-Fi failure → at most one reload per cooldown, and the
    WARP check still runs.
  - DNS runtime down → still exits without touching the portal.

### F03 — FORWARD ACCEPT rules not maintained (High, Likely)

- **What is wrong:** the `FORWARD` policy is DROP and fw3 ends in `reject`.
  LAN→WARP traffic is admitted only by the four rules from `tunnel.sh`
  (`-i br-lan -o tun0 ACCEPT` and `-i tun0 -o br-lan RELATED,ESTABLISHED
  ACCEPT`, for IPv4 and IPv6). `nat_rules_ok`/`ensure_nat_and_mss_rules`
  restore NAT and MSS after a firewall reset but not these rules. The probes
  run from the router (`OUTPUT`), so they keep passing.
- **Trigger:** anything that flushes foreign `FORWARD` rules while WARP stays
  up. Examples: `/etc/init.d/firewall stop`/`start` (fw3 flush), or GL.iNet
  firewall changes if they restore whole tables. The wiki already records
  "firewall resets" that remove the Google rules. The result: all
  WARP-routed LAN traffic (public IPv4 outside the exceptions, plus all IPv6)
  is rejected, while every tick reports "Health check passed", with **no
  automatic recovery**.
- **Evidence:** the 08-01 snapshot shows `FORWARD` policy DROP, fw3's trailing
  `reject`, and the custom rules' counters (9,031/18,185 IPv4, 801/732 IPv6).
  Code inspection shows nothing re-adds them except `tunnel.sh`.
- **Fix:** add the four rules to the existing check-and-repair functions,
  using the same `-C || -I` pattern as the 10-08 MSS fix.
- **Risk:** low. **Invariants:** strengthens "public defaults through
  `tun0`".
- **Test:** extend `test_ensure_nat_and_mss_rules_repaired` and
  `test_bidirectional_mss_clamping_checked`: when `-C FORWARD` fails, `-I
  FORWARD` is issued.

### F04 — Campus route repaired by cycling the WAN (Medium, Confirmed)

- **What is wrong:** when `ip route get 10.200.1.11` is not via `eth0` but the
  lease and carrier are fine (they were checked one step earlier),
  `recover_wan` runs `ifdown`/`ifup`. That releases the DHCP lease and gets a
  new address, resetting every WAN flow and the WARP QUIC session (migration
  is disabled). The real defect, a missing `10.0.0.0/8` route, is never
  re-added in place.
- **Trigger:** an `eth0` link flap flushes the manual `eth0` routes while the
  `tun0` default survives.
- **Evidence:** sandbox → `stop_tunnel.sh`, `ifdown wan`, `ifup wan`, and no
  route re-add. 08-01 logs: three consecutive cycles produced `.184`, `.185`
  and `.186`; the tunnel restart one minute later fixed it.
- **Fix:** if the lease and carrier are OK, first
  `ip route replace <CAMPUS_NETS> via <gw> dev eth0 metric 1` and re-check;
  cycle the WAN only if that fails. This needs the `CAMPUS_NETS` default in
  `ensure_network.sh`, identical to `tunnel.sh`'s.
- **Risk:** low. **Invariants:** strengthens "10/8 and 103.21.124/22 on
  eth0".
- **Test:** sandbox, campus route via `tun0` that becomes `eth0` after the
  replace → no `ifdown`/`ifup`.

### F05 — Access token on the command line (Medium, Confirmed)

- **What is wrong:** `curl -u "$USER:$PASS"` exposes the token in
  `/proc/<pid>/cmdline` (world-readable) for up to 30 s per login attempt.
  Any process on the router can read it, including non-root daemons such as
  dnsmasq. Diagnostics' `ps` filters would not capture it.
- **Fix:** feed the credentials on stdin as curl config: `printf 'user =
  "%s:%s"\n' … | curl -K - …`. Backslash and double quote are escaped first
  through a pipe, never through argv.
- **Risk:** low to moderate, because it touches the auth path. Verify the
  exact `Authorization` header against a local test server before deploying.
- **Invariants:** none.
- **Test:** a stub `curl` records argv and stdin → the token is absent from
  argv, and stdin holds a valid `user =` line. Plus a local `python3`
  HTTP-server check of the produced Basic header.

### F06 — Diagnostics storm during persistent failures (Medium, Confirmed)

- **What is wrong:** ten failure branches call `collect_diagnostics.sh` on
  every tick. Each snapshot runs about 9 nslookups, 3 pings and 3 curls (up to
  about 100 s when the WAN is down, holding the lock) and writes 51–79 KB to
  flash. Retention is count-based (24), so a one-hour storm deletes the
  pre-incident and onset snapshots.
- **Evidence:** 21 snapshots in 38 minutes on 08-01; all 24 retained are from
  that afternoon.
- **Fix:** a per-reason cooldown in `ensure_network.sh` (for example 15
  minutes, keyed by a short reason token), so the first snapshot of an
  incident is kept.
- **Risk:** low (fewer duplicates). **Invariants:** none.
- **Test:** sandbox, 3 failing ticks → 1 snapshot.

### F07 — Default-route preference not verified (Medium)

- **What is wrong:** `tunnel_routes_ok` greps `ip route show default` for
  `dev tun0`. Probes bind to `tun0`. If any lower-metric default appears,
  LAN traffic silently bypasses WARP while health passes. Nothing asserts the
  WAN metric 10; `game_mode.sh:130` even hard-codes it.
- **Triggers:**
  - GL.iNet multi-WAN or UI changes reset the WAN metric (netifd's default is
    0).
  - `game_mode.sh on` is interrupted after adding its metric-1 WAN default
    (see F19).
- **Fix (observability only, no restart, since a restart can't fix it):**
  outside game mode, check `ip -4 route get 1.1.1.1` and `ip -6 route get
  2606:4700:4700::1111` for `dev tun0`. On mismatch, log a WARNING naming the
  winning route, plus one rate-limited diagnostic.
- **Risk:** very low. **Invariants:** makes the first invariant observable.
- **Test:** stub `ip route get` returning `eth0` → WARNING logged, no
  restart.

### F08 — Game policy churn every tick (Medium)

- **What is wrong:** each healthy tick runs `-N` (fails), flushes
  `GAME_SESSION_POLICY` twice, appends its 5 rules again, deletes and
  re-inserts the PREROUTING jump, and deletes and re-adds `ip rule 700`.
  That is 12 `iptables` and 5 `ip` calls, plus the gateway lookup. During the gaps, a NEW port-9339
  connection is not marked, and its conntrack entry stays on WARP for its
  lifetime (the original 09-22 failure). Young sessions that have no `/32`
  yet can also lose their restored mark.
- **Evidence:** the sandbox call trace shows the sequence on every steady
  tick. The window lasts a few `iptables` executions (tens of ms on this
  CPU, estimated), twice a minute. I estimate it hits 0.1–1 % of session
  starts; not measured.
- **Fix:**
  - Compare `iptables -t mangle -S GAME_SESSION_POLICY` with the expected
    rule list, and rebuild only on mismatch.
  - Move the jump only if it is not already rule 1.
  - `ip rule add` only if absent (as `google_wan_policy.sh` already does).
- **Risk:** low to moderate (game routing path).
- **Invariants:** none listed; the direct-WAN game behaviour is unchanged.
- **Test:** sandbox steady tick → zero `-F`, `-D PREROUTING` and `rule del`
  calls; a broken chain still rebuilds; the existing table-101 test stays
  green.

### F09 — WARP rotation always rolls back (Medium, Confirmed)

- **What is wrong:** success requires `curl -6 https://www.google.com/…`, but
  Google IPv6 (`2404:6800::/32`) is rejected in `OUTPUT` since 09-23. The
  IPv4 probe isn't bound to `tun0`, and Google IPv4 goes direct via table
  102, so it never tests the new identity. Every attempt registers a new
  Cloudflare device, then restores the old one.
- **Evidence:** sandbox reproduction: "ERROR: The new registration failed;
  cleanup will restore…"; `config.json` (a dummy) was restored.
- **Fix:** probe through `--interface tun0` against Cloudflare's trace by IP
  literal (`https://1.1.1.1/cdn-cgi/trace`,
  `https://[2606:4700:4700::1111]/cdn-cgi/trace`) and require `warp=on` or
  `warp=plus`. The wiki checklist already uses this check.
- **Risk:** low (an operator tool). **Invariants:** none.
- **Test:** the sandbox rotation scenario passes with Google IPv6 rejected,
  and fails when the trace lacks `warp=`.

### F10 — In-client FIFO can cause upload bufferbloat (Medium, Likely)

- **What is wrong:** `enable_dgram(true, 1000, 1000)` together with eager TUN
  reads means that when the uplink is the bottleneck, up to 1,000 packets
  (about 1.3 MB) wait in quiche's unmanaged queue. `tun0`'s `fq_codel`
  (seen in the 08-01 snapshot) never sees that queue. At 40 Mbit/s up, that
  is about 260 ms of extra latency for every flow, game packets included,
  while any device uploads (for example iCloud Photos; Google Photos is
  already direct).
- **Fix (Rust, deferred):** skip the TUN-read branch while
  `conn.dgram_send_queue_len()` is above a small threshold, so the kernel's
  `fq_codel` absorbs and isolates the excess. Shrink the queue as well.
- **Risk:** moderate (data-plane change). It needs a Linux build and a
  measured loaded-latency test. **Test:** a unit test of the gating
  predicate; on the router, ping through `tun0` while saturating upload,
  before and after.

### F11–F30 (Low and Nit), in brief

- **F11:** `check-dns` runs `printf | tr | grep` for each of 79 domains.
  **Fix:** one `awk` pass (165 execs per tick measured; about 5 expected
  after the fix).
  **Test:** same result on a complete list and on a list missing one domain.
- **F12:** routes are added for every address Blinkit ever returned and never
  deleted, so other sites sharing those CDN IPs also skip WARP.
  **Fix:** keep the current plus previous generation in a `/tmp` state file;
  delete older routes.
- **F13:** dnsmasq's SIGHUP also clears its cache. **Fix (first step):** log
  one line when the Blinkit set changes, so the rate becomes visible before
  deciding anything else.
- **F14:** the 09-19 audit removed the "two slow samples ⇒ unhealthy" rule to
  stop false restarts. Nothing now notices a tunnel that answers in 1.5–4 s
  (the 08-07/08-09 failure class). **Fix:** record `time_total`; if it stays
  above 1.5 s for 3 consecutive ticks, log a WARNING plus one rate-limited
  diagnostic, with no restart.
- **F15:** point the diagnostic WARP-IPv6 probe at Cloudflare's IPv6 trace;
  delete the unused `tunnel_internet_v6_ok`.
- **F16:** idle timeout is 0. Unless Cloudflare advertises one (unknown), a
  silently dead path is detected only by the shell watchdog, about 30–60 s
  later. `h3` stream `Finished`/`Reset` events are also ignored (already
  noted on 09-19). **Fix (Rust, deferred):** set an idle timeout of about
  3× keepalive and end the session when the CONNECT stream closes.
- **F17:** `Ok(())` loops straight back to `connect`. If a server repeatedly
  accepts the session and then closes it, the client reconnect-storms.
  **Fix:** apply the backoff when a session lived less than a few seconds.
- **F18:** `NamedTempFile`s hold the key PEM in `/tmp` for the whole session.
  The default SIGTERM action skips destructors, so every `stop_tunnel.sh`
  probably leaves two root-only 0600 files behind. **Fix:** drop the files
  right after quiche loads them.
- **F19:** add `trap 'exit 129' HUP` next to the existing INT/TERM traps in
  `game_mode.sh` and `rotate_tunnel_ip.sh`.
- **F20:** the game-session refresher deletes `/32`s that left conntrack,
  even if the public refresher still needs them for
  `game.clashroyaleapp.com`. Port-9339 traffic is unaffected (policy
  routing); other ports to that IP briefly use WARP. **Fix:** skip deleting
  routes listed in the other route-state files.
- **F21:** the clock is evidenced 86 days behind at boot. The current owner
  check protects ensure-owned locks, but ownerless locks age by wall clock.
  The portal TLS check and the WARP client certificate
  (`not_before = now`) assume a sane clock. **Fix (observability):** log a
  WARNING when the clock is earlier than the scripts' own mtime, and name
  "clock?" when `curl` exits 60.
- **F22:** check that the first four servers are in order, and that no
  `/iitb.ac.in/` zone forward exists. **Caveat:** if GL.iNet rewrites the
  list, this could cause reconfigure churn, so it needs F02's cooldown.
- **F23:**
  - Add `sync` at the end of the promotion SSH command. A power loss seconds
    after deploy could otherwise leave zero-length files: `config.json`
    would then fail forever without re-registering, and `.env` would break
    login.
  - Warn when the local `config.json` differs from the router's, as is
    already done for `blocked_sites.txt`.
- **F24:** our game mark sets bit 18 inside GL.iNet's rule-1099 mask
  (`0xc0000`). Nothing breaks today because rules 690–710 precede GL's. Write
  this down as a mark-bit allocation; change nothing without evidence.
- **F25:** `README.md` documents `cp usque-rs-upstream-v0.1.0 usque-rs` on the
  router, but sync never ships that file. Decide whether to add it (+5.8 MB per
  sync) or verify it once by hand.
- **F26:** documentation drift:
  - `README.md` and `PROJECT_CONTEXT.md` list 5 and 4 campus names; the code
    has 7.
  - `wiki/systems/ipv6.md` says an IPv6 HTTPS probe is a health requirement;
    it is not.
  - `wiki/bugs/warp-forwarding-starvation-2026-08-09.md` describes the
    removed performance samples as active.
  - The GL.iNet rules and the mark-bit allocation are undocumented.
- **F27:**
  - `stop_tunnel.sh` spends about 50 forks on legacy blocklist/WARP-client
    cleanup, and uses `\s` in BusyBox BRE. (Corrected in §14: about 10, since
    each legacy file holds one real entry.)
  - `pending_pkt` in `tunnel.rs` is never set.
- **F28:**
  - "Confirming before restart" is also logged *after* a restart.
  - "campus resolution failed" is misleading: the probe name is pinned
    locally, so it tests dnsmasq, not campus DNS.
- **F29:** the conntrack `awk` hard-codes `192.168.8.`; `game_mode.sh`
  hard-codes metric 10.
- **F30:** `tunnel.sh` restarts odhcpd, then `ensure_network.sh` restarts it
  again 10 s later.

## 4. Previously reported and still open (not counted above)

| From | Item | Relation to this review |
|---|---|---|
| 09-19 §3 | Client stdout/stderr discarded, so no disconnect reasons | Still open; see improvement A6 |
| 09-19 §3 | MTU integration tests copy production logic | Still open |
| 09-19 §4 | ICMPv4 quote fixed at 28 bytes; TUN write errors ignored; CONNECT stream close ignored | Still open; F16 adds the idle-timeout angle |
| 09-19 §5 | Non-transactional promotion; ownerless locks reclaimable after 180 s | Still open; F19 and F21 add the HUP and clock angles |
| 09-19 §6 | `tunnel.sh` clears dynamic routes before resolving and doesn't share the refresh code | Still open. Also: `tunnel.sh:164` picks the default gateway without `dev eth0`, and its `nslookup \| while` pipeline aborts the start under `set -e` if one route insert fails |
| 09-19 §2 | Loaded latency / SQM unmeasured | Still open; F10 is the in-tunnel counterpart |
| google-wan.md | Firewall resets leave a gap until the next tick | F03 shows the FORWARD ACCEPTs are not covered at all |
| known-issues | dnsmasq 2.85 ignores `filter_aaaa`, so game-mode AAAA filtering is ineffective | Unchanged |

## 5. Considered and decided NOT bugs

1. **`nslookup` parsing.** The router prints the server as `Address:\t…#53`
   (no index), so `/^Address [0-9]+: /` matches answers only (format confirmed
   in diagnostics).
2. **`[ "$X" -eq 1 ] && sleep 5` under `set -e`** (`ensure_network.sh:598`).
   dash and bash continue past the false AND-list (tested). BusyBox ash
   follows dash here (not tested).
3. **Overlapping cron runs.** A live `ensure` owner is never displaced, and a
   dead one is recovered at once. PID reuse after a reboot costs at most one
   skipped tick.
4. **Direct probes when WARP is dead.** 8.8.8.0/24 and 8.8.4.0/24 are in
   `google_net4` (verified), so DNS upstreams use the WAN.
5. **IPv6 during fallback** (I suspected a black hole from `forwarding=0`,
   then disproved it). The fallback-state routing table (08-01 19:30) has no
   IPv6 default, so the kernel's no-route entry sends ICMPv6 unreachable
   regardless of the forwarding sysctl, and clients fall back to IPv4 quickly.
6. **MSS.** 1240 = 1280−20−20 and 1220 = 1280−40−20; TCPMSS never raises a
   smaller MSS.
7. **`stop_tunnel.sh` `while -C; do -D` loops** terminate; `-C` and `-D` need
   the same rule and lock.
8. **Every network call is bounded** (curl max-time, `timeout` around
   nslookup, ssh/scp keepalives, `ping -W/-c`). The worst-case tick lasts
   several minutes (two `login.sh` runs of ≤ ~150 s each, plus diagnostics);
   the lock prevents overlap.
9. **Health ticks vs latency.** No correlation in the 08-19 data (§2); that
   data predates F08's code.
10. **`tun0` vanishing mid-run.** The kernel drops `tun0` routes, IPv4 falls
    back to the WAN default automatically, and the next tick restarts WARP.
11. **Rust hot path.** No `unwrap`/`expect` on packet data. The datagram buffer
    (1,411 B) exceeds the maximum UDP payload (1,350), so `dgram_recv` can't
    stall. IHL is validated and options are checksummed. `select!` is
    unbiased, and pacing doesn't block receive.
12. **Rust `Config::save`.** 0600 temp file, fsync, then atomic rename. No
    directory fsync, so the worst case is the previous file, not corruption.
13. **Rollback CLI compatibility.** The upstream binary contains
    `interface-name`. `--congestion-control` and `--ready-file` are
    feature-detected, and the readiness check falls back correctly.
14. **Google policy** installs its rules only if absent: no per-tick churn.
15. **`iptables` without `-w`.** Zero xtables-lock errors in all logs, and
    fw3 uses libiptc rather than the CLI lock. Not worth a broad edit.
16. **`login.sh` TLS.** Verification is on, redirects are https-only, and
    query strings are redacted. `--location-trusted` is a documented
    dependency.
17. **Duplicated defaults.** 12 variables are defined 2–4 times each, and
    every copy currently has the same value. That is a drift risk only; see
    A1.
18. **Deployed binary.** Its SHA-256 matches the wiki (`1ee312fc…`).
    `usque-rs-optimized/usque-rs-aarch64-openwrt` (`524622a6…`) is an older
    build, not the deployed one.

## 6. Proposed architecture improvements

| # | Improvement | Benefit | Cost | Risk | Incremental? |
|---|---|---|---|---|---|
| A1 | One sourced `defaults.sh` for the 12 duplicated policy variables | Ends list drift (four past incidents were "name missing from a list") | Touch about 10 scripts | Low–moderate (`set -u`, source order) | Yes, one variable group per commit |
| A2 | Stage-isolated pipeline: per-stage status and cooldown; Wi-Fi, LAN-IPv6 and Google never gate WAN/portal/WARP | Removes the F02 class for good | Moderate refactor of `ensure_network.sh` | Moderate | Yes; F02 is step one |
| A3 | Event-driven reapply: an fw3 include plus a hotplug hook calling one idempotent "reapply firewall/marks" script | Closes the reset gap (F03, Google) within seconds instead of ≤ 30 s or never | Small script plus one UCI include | Moderate (runs on every fw3 reload; must be fast and idempotent) | Yes |
| A4 | One lock helper for all four lock users: owner PID, lock in `/var/run` (tmpfs) | No stale locks after reboot; no clock-age heuristics | Small | Low | Yes |
| A5 | Diagnostics policy: rate-limited per reason, redacted, 0600, first-of-incident kept | Better evidence, less flash wear | Small | Low | Yes (F01, F06) |
| A6 | Client event log: drop `\r` status lines and send the rest to `logger -t usque-rs` (RAM ring buffer) | Disconnect reasons become visible | Small (shell only) | Low | Yes |
| A7 | Rust liveness and queueing: backpressure, finite idle timeout, stream-close handling, PEM cleanup | Latency under load; faster self-recovery | Needs a Linux CI/build (OrbStack + `cross`) and a planned binary rollout | Moderate | Yes, behind measurements |
| A8 | Pipeline simulation harness in `tests/` (this audit's sandbox, cleaned up) | End-to-end tests of the recovery state machine | Moderate, one-time | None (test-only) | Yes |
| A9 | Platform-assumption check once per boot: WAN metric, radio section names, required binaries (`ipset`, `iptables`, `conntrack`, `jsonfilter`, `timeout`) | Clear "platform changed" errors after firmware updates | Small | Low | Yes |
| A10 | Documented mark-bit and rule-priority allocation, including GL.iNet's | Prevents future collisions (F24) | Docs only | None | Yes |

Not recommended: a procd respawn service for `usque-rs`. The 30 s watchdog plus
readiness gating already covers crashes, and respawning without the
route/readiness logic would bypass it.

## 7. Suggested implementation batches (for your approval)

| Batch | Items | My recommendation |
|---|---|---|
| 1 Security | F01, F05 | Approve; smallest diffs, no connectivity impact |
| 2 Recovery correctness | F03, F02, F04, F06 | Approve; F02 with the sandbox pipeline tests (A8) |
| 3 Policy hygiene | F07 (log-only), F08, F09, F11, F15 | Approve |
| 4 Low/observability | F12, F13 (log first), F14 (log only), F19, F20, F22, F23, F26–F30 | Your choice; all small |
| 5 Rust (source + tests only) | F10, F16, F17, F18 | Defer unless you allow OrbStack/`cross` to run tests; no binary would be rebuilt |
| Needs your decision | F21, F24, F25 | Observability line for F21; docs only for F24; F25 is a deploy-policy choice |

**Tooling I need for Phase 2:** permission to install `shellcheck` (Homebrew)
for the required `shellcheck -s sh` runs. pytest is optional, since the tests
run with `unittest`. For batch 5, permission to start OrbStack and let
`cross`/cargo download crates.

## 8. Phase 2 outcome per finding

You approved batches 1–3. Every fix landed as one commit with a test that
fails before it and passes after. Test infrastructure came first, as its own
commit `c5ca173` (`tests/sandbox.py`, a test-only version of A8).

| ID | Status | Commit | Notes |
|---|---|---|---|
| F01 | **Fixed** | `147c151` | Wireless key/password/secret/PSK values redacted (escaped quotes handled); snapshots `umask 077`. Existing snapshots still hold passphrases: your action. |
| F02 | **Fixed** | `61f5c43` | Wi-Fi and DNS-config failures capture once, cool down 5 min (`STAGE_REPAIR_COOLDOWN`) and continue. A dead resolver still ends the run, but its repair is rate-limited too. |
| F03 | **Fixed** | `a1fb67c` | The four LAN↔`tun0` FORWARD rules are checked and repaired with the same specs as `tunnel.sh`; a repair is now logged. |
| F04 | **Fixed** | `7b3fa2f` | `CAMPUS_NETS` re-added via the WAN gateway; the WAN is cycled only if that fails. |
| F05 | **Fixed** | `a2cafe5` | Credentials reach curl on stdin (`-K -`), escaped; checked against real curl. |
| F06 | **Fixed** | `0b09c86` | One failure snapshot per reason per 15 min (`DIAGNOSTICS_COOLDOWN`). |
| F07 | **Fixed (log only)** | `6c7a43c` | WARNING plus one snapshot when 1.1.1.1 or 2606:4700:4700::1111 does not route via `tun0`; never restarts. |
| F08 | **Fixed** | `c6050ec` | Rule 700, the chain and the PREROUTING jump change only on drift; the rule lines themselves are unchanged. |
| F09 | **Fixed** | `a883824` | Rotation requires `warp=on`/`warp=plus` from Cloudflare's trace through `tun0`, for both families. |
| F11 | **Fixed** | `9968823` | One `awk` pass; equivalence tests for the complete and missing-domain cases. |
| F15 | **Fixed** | `237f970` | IPv6 WARP probe uses Cloudflare's trace by IP literal; dead `tunnel_internet_v6_ok` removed; README wording updated. |
| F10, F16, F17, F18 | Deferred | — | Rust (batch 5): not approved this round; needs a Linux build/test environment and, for F10, a loaded-latency measurement first. |
| F12–F14, F19–F30 | See §14 (F12: §15) | — | Approved on 2026-10-21 as batch 4, with your decisions on F21, F24 and F25. Deployed on 2026-10-22, except the F12 fix (§15). |

Rejected: none. In Phase 1 I had already dropped one suspected issue, the
IPv6 "black hole" during fallback, after the evidence disproved it (§5 item 5).

Tests: 48 in total (21 original, 27 new), all passing under both macOS
`/bin/sh` (bash 3.2 in POSIX mode) and `dash`, for every commit.
`shellcheck -s sh` (0.11.0) reports no new findings in any changed script.
The remaining findings are pre-existing: SC1090/SC1091 for the dynamic
`source` of `paths.sh` and `.env`, SC2012 in `collect_diagnostics.sh` (`ls`
for retention), and two SC2086 in `login.sh` (intentional splitting of
`$RESOLVE_OPTS`). Run the suite with
`python3 -m unittest discover -s tests` (about 2 minutes).

## 9. Measured effect (sandbox, same harness for before and after)

- **Processes per healthy tick:** 442 at `2ba81fe`, 290 at `HEAD` (−34 %).
  `grep` drops 129 → 53 and `tr` 83 → 0 (F11). This counts every process,
  real tools included, under dash on macOS. BusyBox NOFORK/NOEXEC applets
  make some of them cheaper on the router.
- **Game-policy changes per healthy tick:** 13 → 0 (F08).
- **Unrepairable DNS drift.** Before: every tick restarted dnsmasq and
  dnscrypt-proxy, committed UCI, took a snapshot, and never reached portal or
  WARP recovery. After: one repair and one snapshot per 5 minutes, and portal
  and WARP recovery still run (`test_pipeline.py`).
- **Persistent failure.** Before: one snapshot per tick. After: one per reason
  per 15 minutes.
- **Not measured:** CPU time and wall time on the router, and how often the
  F03, F04 and F08 trigger conditions occur in practice.

## 10. Invariant re-check against the final diff

All seven still hold.

1. **Public IPv4 and IPv6 defaults via `tun0`; campus prefixes, endpoints and
   split-horizon `/32`s on `eth0`.**
   - `tunnel.sh` and `stop_tunnel.sh` are unchanged.
   - The only new route-changing line re-adds `CAMPUS_NETS` via the WAN
     gateway at metric 1. It uses the same default list as `tunnel.sh` and
     `stop_tunnel.sh` (all three identical).
   - F07 is read-only.
   - The four F03 rules match `tunnel.sh`'s character for character (checked
     mechanically).
2. **DNS strict-order chain; only the listed campus hosts forwarded.**
   - `configure_dns.sh` and every `dns_config_ok` predicate are unchanged.
   - F02 changes only *when* a repair runs.
   - F11 is an equivalent check (equivalence tests).
3. **`filter_aaaa=0`, `ra_default=2`, `block_ipv6=false`, ULA + NAT66, MSS on
   `tun0`.**
   - The LAN-IPv6 and DNS configurators and their checks are unchanged.
   - The NAT and MSS checks are unchanged and now extended (F03).
4. **Bounded recovery.**
   - The WARP restart, 5-minute cooldown and direct-IPv4 fallback logic is
     unchanged; only its snapshot call is now rate-limited.
   - A lost lease still stops the tunnel and recovers `wan` first.
   - F02 adds cooldowns.
   - F04 still falls back to `recover_wan`.
5. **`.env`/`config.json` 0600; atomic registration writes.**
   - `tunnel.sh`'s `chmod` lines, the Rust source and rotation's
     backup/restore code are unchanged; F09 changed only the success probes.
   - F05 writes no files.
6. **Wi-Fi IN / HE20 / HE80.** `configure_wifi.sh` and `wifi_config_ok` are
   unchanged. A repair that keeps failing is retried every 5 minutes instead
   of every tick.
7. **Rollback to `usque-rs-upstream-v0.1.0`.** `tunnel.sh`, the binaries and
   the CLI flags are untouched.

## 11. Deployment checklist

**What to deploy:** six scripts: `diagnose.sh`, `collect_diagnostics.sh`,
`login.sh`, `google_wan_policy.sh`, `rotate_tunnel_ip.sh`, `ensure_network.sh`.
`tests/`, `wiki-llm/` and the README change stay on the Mac.

**Don't use `sync_to_router.sh` for this.** It stops WARP to promote, and it
also pushes the Mac's `.env`, `config.json` and every other file. The steps
below keep WARP running.

**Order:**

1. **Step A (low risk, any time):** the first five files. `rotate_tunnel_ip.sh`
   only runs when you invoke it.
2. **Step B (the watchdog):** `ensure_network.sh`, at a time you can watch for
   an hour (not just before a match).

**1. Stage from the Mac:**

```sh
cd /Users/atharva/projects/router-script
FILES="diagnose.sh collect_diagnostics.sh login.sh google_wan_policy.sh rotate_tunnel_ip.sh ensure_network.sh"
tar -cf - $FILES | ssh -o BatchMode=yes root@192.168.8.1 'umask 077; cd /root/router-script && rm -rf .stage-20261020 && mkdir .stage-20261020 && tar -xf - -C .stage-20261020'
shasum -a 256 $FILES
```

**2. On the router (`ssh root@192.168.8.1`): verify and back up.** Nothing
changes yet.

```sh
cd /root/router-script
FILES="diagnose.sh collect_diagnostics.sh login.sh google_wan_policy.sh rotate_tunnel_ip.sh ensure_network.sh"
for f in $FILES; do sh -n ".stage-20261020/$f" || echo "SYNTAX FAIL $f"; done
sha256sum .stage-20261020/*.sh          # must equal the Mac's shasum output
mkdir -m 700 -p backup-20261020 && cp -p $FILES backup-20261020/
pidof usque-rs > backup-20261020/warp-pid-before
# Waits up to 2 min for a running health check; returns non-zero if busy.
take_lock() { n=0; until mkdir .ensure_network.lock 2>/dev/null; do [ "$n" -ge 120 ] && return 1; sleep 1; n=$((n+1)); done; }
promote() { for f in "$@"; do cp ".stage-20261020/$f" "$f.new" && chmod 755 "$f.new" && mv "$f.new" "$f"; done; }
```

`mv` replaces each file atomically, so a script that is already running keeps
reading the old copy.

**3. Step A:**

```sh
take_lock && { promote diagnose.sh collect_diagnostics.sh login.sh google_wan_policy.sh rotate_tunnel_ip.sh; rmdir .ensure_network.lock; } || echo "lock busy: nothing changed, retry"
```

**4. Step B, then one real health run.** The lock must be released first:
the 2026-10-08 helper ran its health check while holding the lock, so that
run only logged "Skipped".

```sh
take_lock && { promote ensure_network.sh; rmdir .ensure_network.lock; } || echo "lock busy: nothing changed, retry"
sh ./ensure_network.sh; tail -n 5 logs/ensure.log
[ "$(cat backup-20261020/warp-pid-before)" = "$(pidof usque-rs)" ] && echo "WARP PID preserved"
rm -rf .stage-20261020
```

**5. Post-deploy checks (read-only):**

- **F01:** `sh diagnose.sh | grep -n '"key"\|password'` shows only
  `<redacted>` values. The next snapshot in `ls -l diagnostics | tail -n 2`
  is `-rw-------`.
- **F15:** `sh diagnose.sh | grep warp_ipv6_status` gives
  `warp_ipv6_status=200`.
- **F05:** `grep -c -- '-K -' login.sh` gives `1`. Optional parser check with
  fake credentials against the router's own web server:
  `printf 'user = "test:test"\n' | curl -sv -K - -o /dev/null http://127.0.0.1/ 2>&1 | grep -i '^> authorization'`
  should print `> Authorization: Basic dGVzdDp0ZXN0`.
- **F11:** `sh google_wan_policy.sh check-dns; echo "exit=$?"` gives
  `exit=0`.
- **F03:**
  `iptables -C FORWARD -i br-lan -o tun0 -j ACCEPT && ip6tables -C FORWARD -i br-lan -o tun0 -j ACCEPT && echo forward-ok`.
- **F08:** run `iptables -t mangle -L GAME_SESSION_POLICY -v -n` twice, a
  minute apart. The packet counters should keep growing; before this fix they
  reset every 30 s because the chain was flushed. `ip rule show | grep -c '^700:'`
  gives `1`.
- **F07:** `ip -4 route get 1.1.1.1; ip -6 route get 2606:4700:4700::1111`
  shows `dev tun0` for both.
- **F09 (optional; briefly interrupts WARP):** `sh rotate_tunnel_ip.sh` should
  end with "SUCCESS".

**6. First hour.** Watch `tail -f logs/ensure.log`.

- **Expected:** "Starting health check." and "Health check passed." twice a
  minute, and an unchanged `pidof usque-rs`.
- **Informational new lines:**
  - "Reinstalled missing tunnel NAT, MSS or LAN forwarding rules in place."
    means a firewall reset happened that was previously silent.
  - "Reinstalled campus routes on eth0 without cycling the WAN."
  - "… repair cooldown is active …"
  - "Diagnostics for … were captured recently …"
- **Act on:**
  - "WARNING: public traffic does not prefer tun0". Check
    `ip -4 route show default` for a lower-metric default, for example a WAN
    metric reset in the GL.iNet UI.
  - "Skipped: health check PID … owns the maintenance lock" persisting for
    minutes.
  - Any "configure_*.sh failed".
  - Game-policy counters resetting.

**7. Rollback.**

Full rollback, on the router:

```sh
cd /root/router-script
take_lock() { n=0; until mkdir .ensure_network.lock 2>/dev/null; do [ "$n" -ge 120 ] && return 1; sleep 1; n=$((n+1)); done; }
take_lock && { for f in diagnose.sh collect_diagnostics.sh login.sh google_wan_policy.sh rotate_tunnel_ip.sh ensure_network.sh; do cp -p "backup-20261020/$f" "$f.old" && mv "$f.old" "$f"; done; rmdir .ensure_network.lock; } || echo "lock busy: retry"
rm -f /tmp/router-script-wifi-repair-retry-after /tmp/router-script-dns-config-retry-after /tmp/router-script-dns-runtime-retry-after
rm -rf /tmp/router-script-diagnostics-after
```

No route, firewall, UCI or service state needs reverting. The only state these
changes create is the FORWARD rules and campus routes that `tunnel.sh` already
installs, plus the `/tmp` markers removed above.

Rolling back one finding: run `git revert <commit>` on the Mac, then redeploy
the listed file with steps 1–4. For a single-file emergency rollback on the
router, use `cp -p backup-20261020/<file> <file>`.

| Finding | Commit | Files | Revert order |
|---|---|---|---|
| F01 | `147c151` | `diagnose.sh`, `collect_diagnostics.sh` | independent |
| F05 | `a2cafe5` | `login.sh` | independent |
| F11 | `9968823` | `google_wan_policy.sh` | independent |
| F09 | `a883824` | `rotate_tunnel_ip.sh` | independent |
| F15 | `237f970` | `diagnose.sh`, `ensure_network.sh` | independent |
| F03 | `a1fb67c` | `ensure_network.sh` | independent |
| F04 | `7b3fa2f` | `ensure_network.sh` | independent |
| F08 | `c6050ec` | `ensure_network.sh` | independent |
| F07 | `6c7a43c` | `ensure_network.sh` | before F06 (it uses F06's helper) |
| F06 | `0b09c86` | `ensure_network.sh` | after F07, before F02 (it uses F02's retry helpers) |
| F02 | `61f5c43` | `ensure_network.sh` | after F06 and F07 |

## 12. What I could not verify

- **Nothing ran on the router.** Every behavioural claim comes from the
  sandbox (stubbed system commands) under `dash` and macOS `bash --posix`,
  not BusyBox ash.
- **OpenWrt tool semantics, assumed but untested on the device:**
  - BusyBox `sed -E` with the redaction regex (musl regex).
  - BusyBox `awk -v` with `index()`, and `grep -c --`.
  - The router's curl for `-K -` and `-g`. Only macOS curl 8.7.1 was used,
    including a real Basic-auth round trip against a localhost server.
  - `iptables -C` for the CONNMARK/MARK rules with masks.
  - `iptables -S` output for the PREROUTING jump and `--restore-mark`. The
    rule-700 check uses the same `ip rule show` pattern style as the Google
    policy check that already works in production.
- **Cloudflare's trace reporting `warp=on` through this MASQUE registration.**
  The wiki's deployment checklist says it does; I didn't re-verify it.
- **Real triggers.** The firewall flush (F03), persistent Wi-Fi/DNS failure
  (F02) and campus-route loss (F04) were tested only as logic, not on
  hardware. The real size of the F08 windows, and how they affected game
  sessions, were not measured.
- **CPU and time.** Process counts were measured on macOS; router CPU and
  wall time were not measured.
- **Deferred items.** Everything deferred is unchanged. The Rust client was
  neither built nor tested (Docker is not running and the crates are not
  cached).
- **Existing snapshots.** Snapshots that already contain Wi-Fi passphrases,
  on the router and on the Mac, were left untouched.

## 13. Deployment record — 20 October 2026, 21:15–21:22 IST

You authorised SSH access for this deployment; it followed §11 with extra
read-only gates. `.env` and `config.json` were never read.

**Pre-flight.** All six scripts on the router matched the baseline `2ba81fe`
byte for byte. WARP was running (PID 4495), no lock was held, `/overlay` was
17 % and `/tmp` 0 % used, and health checks were passing every 30 s.

**Staging.**
- The first attempt sent an empty archive: my local shell is zsh, which
  doesn't split an unquoted `$FILES`. The hash and syntax gate failed as
  designed, and nothing was promoted.
- I re-staged with the filenames written out. All six files passed BusyBox
  `sh -n`, and their hashes matched the Mac.

**Read-only dry runs on live data, before any promotion:**
- **F11:** the old and new `check-dns` both exit 0 on the live UCI list; the
  new one exits 1 when a domain is missing (BusyBox `awk` verified).
- **F01:** BusyBox `sed -E` redacts both live passphrases, leaves no values
  and keeps the SSIDs.
- **F05:** the router's curl 7.83.1 reads the stdin config and sends exactly
  `Basic base64("test:p\"q\\r")` for the fake credentials.
- **F15/F09:** Cloudflare's trace through `tun0` reports `warp=on` for IPv4
  and IPv6. The new IPv6 probe returns 200; the old Google probe returns 000.
- **F08:** against the live `iptables -S` output and `-C` matching, the chain
  is intact (5 rules, restore rule first), the jump is the first PREROUTING
  rule, and rule 700 exists once.
- **F07/F03:** both route probes select `tun0`, and all four FORWARD rules
  are present.

**Step A** (five scripts), promoted under the lock at about 21:16. The
backup is in `/root/router-script/backup-20261020` (mode 700; six scripts
plus the WARP PID). Verified:
- The deployed `check-dns` exits 0.
- `login.sh` uses `-K -`.
- A new snapshot is `-rw-------`, with 2 fields redacted and 0 left.
- `warp_ipv6_status=200`.
- The scheduled ticks at 21:17:00 and 21:17:30 passed, and the PID was
  unchanged.

**Snapshots on the router.** 25 files held 50 passphrase values. Each was
rewritten only after checking: identical line count, exactly the secret lines
changed, none left.
- The first pass skipped all 25 because BusyBox has no `diff`; no content
  changed.
- I re-ran it with an `awk` comparison: 25 of 25 redacted.
- All 30 snapshots are now `-rw-------`, with 0 secret values left. Copies
  pulled to other machines, such as the redacted Mac copy, are unaffected.

**Step B** (`ensure_network.sh`), promoted under the lock at 21:19:02. A
manual health run with the lock released passed, and the PID was unchanged.
The PREROUTING jump counter grew from 133 to 387 packets during that run,
meaning the jump was no longer torn down.

**Watch of the scheduled ticks, 21:19–21:22, sampled every 30 s:**
- Every tick passed.
- Since step A, ensure.log has 31 lines, all "Starting health check." or
  "Health check passed."; nothing else was logged.
- The WARP PID stayed 4495 throughout; WARP was never restarted.
- Rule 700 stayed single and the chain kept its 5 rules.
- The PREROUTING jump counter rose monotonically (1,817 → 5,455 → 10,911 →
  15,417 → 19,325 → 23,063 → 26,810 packets). Under the old script it
  reset every 30 s, so F08 is confirmed in production.
- The staging directory was removed. The backup stays in
  `/root/router-script/backup-20261020` for §11's rollback commands.

**Items from §12 now verified on the router:** BusyBox `sh -n`, `sed -E`
redaction, `awk -v`/`index()`, curl 7.83.1 `-K -` and `-g`, `iptables -C`
and `-S` for the game chain, the rule-700 `ip rule show` check, and
Cloudflare's trace reporting `warp=on` through `tun0`.

**Still unverified:**
- **F05 in a real login:** the token path runs only on a real portal
  re-login; the last ones (2026-10-17 and 10-18) used the old script. Watch
  `logs/login.log` at the next one.
- **F02, F03, F04, F06 and the F07 warning** only act on failures, so none
  were exercised. They are covered only by the sandbox tests.
- **The rest of the first hour:** the §11 watch list is yours to follow.

## 14. Batch 4 — approved 21 October 2026, deployed 22 October (§15)

You approved batch 4 and decided the three open items: F21 log only, F24
documentation only, F25 ship the rollback binary. Each code change landed as
one commit with a test that fails before it. It was deployed on 22 October;
§15 records that, and the F12 fix that followed.

### 14.1 Outcome per finding

| ID | Status | Commit | Notes |
|---|---|---|---|
| F12 | **Correction withdrawn; fixed in §15** | `0e3ad17` (test), `775bcd4` (fix) | This row first said the finding was mostly not a defect: on a healthy tick the public refresher removes a replaced address's route. That holds only on healthy ticks. The post-deploy check on 2026-10-22 found 20 leaked routes, and the fix followed (§15). |
| F13 | **Fixed (log only)** | `172c205` | One timestamped `ensure.log` line per record change, with the number of dnsmasq PIDs actually signalled. Its rate answers F12's open question: is removal within one tick too fast for clients that cached the old answer? |
| F14 | **Fixed (log only)** | `99eab50` | The passing probe's `time_total` is kept. Three consecutive checks over 1.5 s log a WARNING and take one `tunnel-slow` snapshot; one fast check resets the count. It never restarts. Tunables: `TUNNEL_SLOW_SECONDS`, `TUNNEL_SLOW_CHECKS`. |
| F19 | **Fixed** | `3994808` | `trap 'exit 129' HUP` in both scripts. The trap alone was not enough for rotation: the test showed `cleanup`'s first `log` (a `tee`) failing on the lost terminal, and `set -e` aborting the restore with status 141. That log call is now non-fatal. `game_mode.sh` only releases its lock; partial game-mode state remains, and F07's warning reports it. |
| F20 | **Fixed** | `bf012b8`, `575bb11` | A `/32` is deleted only once no other refresher's file lists it, at both deletion sites. The first commit also adds the repo's first shellcheck directive, for a false-positive SC2094; the second makes the unit test use the real helper. |
| F21 | **Fixed (log only)** | `d0d18db` | `ensure_network.sh` warns when `"$0" -nt "$LOG_FILE"`, comparing against the log line it just wrote, so the check costs no process. `login.sh` names the clock on curl exit 60, "not yet valid" or "certificate has expired". |
| F22 | **Fixed** | `4b3c531` | The first four servers must match the strict-order chain, and only the listed hosts may be forwarded to campus DNS (a whole-zone forward is drift). `configure_dns.sh` rewrites the whole list, so the existing repair fixes both. The 2026-08-01 snapshot's list passes. Churn risk if GL.iNet rewrites the list: bounded by F02's 5-minute cooldown, and gated before deployment (§14.4). |
| F23 | **Fixed** | `f548383` | The promotion ends with `sync`. A local `config.json` whose SHA-256 differs from the router's is refused unless `--force` is given. Contents are never printed, and a router with no registration still deploys. `tests/test_sync.py` is the first test of `sync_to_router.sh` (stub ssh/scp, `.invalid` target, dummy files only). |
| F24 | **Documented** | `6ff4eeb` | New page `wiki/systems/policy-routing.md`: the rule order (ours plus GL.iNet's), mark-bit owners, the overlap, and rules for new marks. The mask is unchanged. |
| F25 | **Fixed** | `8164762` | `usque-rs-upstream-v0.1.0` is in the deploy set, with a guarded `chmod 755`. Cost: about 6 MB more per sync, and staging now holds both binaries (about 12 MB) on `/overlay` until promotion. The README rollback checks for the file first. |
| F26 | **Fixed** | `26d8b5d` | Campus name lists (7), IPv6 health text, and the 08-09 page's slow-sample rule marked historical. The GL.iNet rules are on F24's page. |
| F27 | **Fixed (shell half)** | `9629f58` | One `tr` per file, `case` for comments (BusyBox `grep` has no `\s`). Corrected estimate: about 10 processes per stop before, 2 after (the commit message says "about three", counting only `tr`). The Rust half (`pending_pkt`) stays deferred with F10 and F16–F18. |
| F28 | **Fixed** | `113a1e1` | Restart-path and DNS-runtime messages say what happened. |
| F29 | **Fixed** | `a6ea218` | LAN prefix from `LAN_SUBNET`; `game_mode.sh off` uses the UCI WAN metric (10 here, so no change). |
| F30 | **Fixed** | `bacac56` | One odhcpd restart per WARP restart (`tunnel.sh`'s). |
| docs | — | `fa8c1ff` | Wiki pages that batch-4 code contradicted, repaired afterwards (the contract asks for the same commit; noted as a lapse). |

Tests: 72 (24 more than after batches 1–3), all passing under macOS `/bin/sh`
and `dash`. `shellcheck -s sh` findings in every changed script are identical
to the 2026-10-20 deployed state (`41828c5`).

### 14.2 Measured effect

- Processes per healthy tick: 290 → 292. The two extra are one `awk` each
  for F22 and F14. Game-policy changes per tick stay at 0. This was measured
  with the same harness as §9.

### 14.3 Invariant re-check

All seven still hold. `configure_dns.sh`, `configure_lan_ipv6.sh`,
`configure_wifi.sh`, `tunnel.sh` and `google_wan_policy.sh` are unchanged
since `41828c5`.

1. **Defaults via `tun0`; campus, endpoints and split-horizon `/32`s on
   `eth0`.** F20 only withholds deletions. F14 and F21 only log. F29 derives
   the values this router already uses. F27 changes only how the legacy files
   are read.
2. **DNS chain and campus forwards.** F22 now enforces both, including "never
   the whole zone".
3. **`filter_aaaa=0`, `ra_default=2`, `block_ipv6=false`, ULA + NAT66, MSS.**
   The configurators and their checks are unchanged. `game_mode.sh` gains
   only the HUP trap and the F29 metric. F30 drops a redundant odhcpd restart.
4. **Bounded recovery.** The restart, cooldown and fallback code is
   unchanged, and F14's test asserts that it never restarts.
5. **`.env`/`config.json` 0600; atomic registration.** Sync still sets 0600
   (now tested). Rotation's backup and restore are unchanged, except that a
   failed log write can no longer abort the restore.
6. **Wi-Fi IN / HE20 / HE80.** Unchanged.
7. **Rollback binary.** Now actually shipped (F25). `tunnel.sh` and both
   binaries are unchanged.

### 14.4 Deployment checklist (batch 4)

**What:** six router scripts (`ensure_network.sh`, `stop_tunnel.sh`,
`game_mode.sh`, `refresh_blinkit_dns.sh`, `login.sh`,
`rotate_tunnel_ip.sh`) and the rollback binary. `sync_to_router.sh` runs on
the Mac and needs no router deploy. As in §11, use the staged steps below,
not `sync_to_router.sh`.

**0. Pre-flight (read-only).** On the Mac, list the expected current hashes:

```sh
cd /Users/atharva/projects/router-script
for f in ensure_network.sh stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh; do printf '%s  %s\n' "$(git show 41828c5:"$f" | shasum -a 256 | cut -d' ' -f1)" "$f"; done
shasum -a 256 usque-rs-upstream-v0.1.0
```

On the router, these must match:

```sh
cd /root/router-script
sha256sum ensure_network.sh stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh
ls -l usque-rs-upstream-v0.1.0 2>/dev/null && sha256sum usque-rs-upstream-v0.1.0 || echo "rollback binary absent"
df -h /overlay /tmp
```

Stop if a script differs (pull the router's copy first). Also stop if a
rollback binary is present with a different hash, and ask before replacing a
copy that may have been tested. Then run the **F22 gate**. It applies the new
check, verbatim, to the live list:

```sh
uci -q get dhcp.@dnsmasq[0].server | awk -v want="8.8.8.8 8.8.4.4 10.200.1.11 127.0.0.1#5453" -v dns=10.200.1.11 \
  -v allowed=" internet.iitb.ac.in sso.iitb.ac.in cc.iitb.ac.in moodle.iitb.ac.in portal.iitb.ac.in mulyankan.cse.iitb.ac.in webmail.iitb.ac.in " '
  { n = split(want, w, " "); for (i = 1; i <= n; i++) if ($i != w[i]) bad = 1
    for (i = 1; i <= NF; i++) { parts = split($i, part, "/"); if (parts < 3 || part[parts] != dns) continue
      for (j = 2; j < parts; j++) if (index(allowed, " " part[j] " ") == 0) bad = 1 } }
  END { exit bad }' && echo "F22 gate: pass" || echo "F22 gate: FAIL - do not do step B"
```

A failure means the first new tick would rewrite the DNS config and restart
dnsmasq. In that case, look at the list (it holds no secrets) and decide
before step B.

**1. Stage from the Mac** (file names written out; zsh does not split
`$FILES`):

```sh
tar -cf - ensure_network.sh stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh usque-rs-upstream-v0.1.0 | ssh -o BatchMode=yes root@192.168.8.1 'umask 077; cd /root/router-script && rm -rf .stage-batch4 && mkdir .stage-batch4 && tar -xf - -C .stage-batch4'
shasum -a 256 ensure_network.sh stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh usque-rs-upstream-v0.1.0
```

**2. Verify and back up on the router:**

```sh
cd /root/router-script
FILES="ensure_network.sh stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh"
for f in $FILES; do sh -n ".stage-batch4/$f" || echo "SYNTAX FAIL $f"; done
sha256sum .stage-batch4/*               # must equal the Mac's shasum output
mkdir -m 700 -p backup-batch4 && cp -p $FILES backup-batch4/
pidof usque-rs > backup-batch4/warp-pid-before
take_lock() { n=0; until mkdir .ensure_network.lock 2>/dev/null; do [ "$n" -ge 120 ] && return 1; sleep 1; n=$((n+1)); done; }
promote() { for f in "$@"; do cp ".stage-batch4/$f" "$f.new" && chmod 755 "$f.new" && mv "$f.new" "$f"; done; }
```

**3. Step A**, the scripts outside the watchdog. `refresh_blinkit_dns.sh` runs
every tick but only gains a log line, `login.sh` runs on portal recovery, and
the rest run on demand or on a WARP restart:

```sh
take_lock && { promote stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh; rmdir .ensure_network.lock; } || echo "lock busy: nothing changed, retry"
```

**4. Step B**, the watchdog, at a time you can watch for an hour. Only after
the F22 gate passes:

```sh
take_lock && { promote ensure_network.sh; rmdir .ensure_network.lock; } || echo "lock busy: nothing changed, retry"
sh ./ensure_network.sh; tail -n 6 logs/ensure.log
[ "$(cat backup-batch4/warp-pid-before)" = "$(pidof usque-rs)" ] && echo "WARP PID preserved"
```

**5. Step C (F25)**, the rollback binary:

```sh
cp .stage-batch4/usque-rs-upstream-v0.1.0 usque-rs-upstream-v0.1.0.new && chmod 755 usque-rs-upstream-v0.1.0.new && mv usque-rs-upstream-v0.1.0.new usque-rs-upstream-v0.1.0
sha256sum usque-rs-upstream-v0.1.0      # must equal the Mac's
rm -rf .stage-batch4
```

**6. Post-deploy checks (read-only):**

- **F22:** `grep -c 'DNS configuration drift detected' logs/ensure.log` does
  not grow.
- **F21:** `grep -c 'WARNING: the clock reads' logs/ensure.log` is 0 while
  the clock is synced.
- **F14:** `cat /tmp/router-script-tunnel-slow-count 2>/dev/null || echo "no slow checks"`.
- **F13:** `grep 'Blinkit DNS: records changed' logs/ensure.log | tail -n 3`.
  The rate over a day is the data F12's open question needs.
- **F12/F20 route ownership.** The following lists metric-1 host routes on
  `eth0` that no state file owns. Expect only the WARP endpoint routes. It
  writes one temporary file and removes it.

  ```sh
  cat /tmp/router-script-*-host-routes 2>/dev/null | sort -u > /tmp/owned-routes
  ip -4 route show | awk '$1 ~ /^[0-9.]+$/ && / dev eth0 / && / metric 1/ {print $1 "/32"}' | sort -u | grep -vxF -f /tmp/owned-routes
  rm -f /tmp/owned-routes
  ```

**7. First hour.** Same as §11, plus:

- **Informational:** "Blinkit DNS: records changed (N entries); dnsmasq PIDs
  reloaded: 1 …".
- **Act on:**
  - "WARNING: the tunnel probe took over 1.5s …": WARP is slow. Nothing
    restarts automatically; compare with `sh monitor_game_network.sh`.
  - "WARNING: the clock reads …": check NTP and `date`.
  - "DNS configuration drift detected" every 5 minutes: GL.iNet is rewriting
    the list (F22 churn). Roll back F22.
  - In `logs/login.log`, "TLS verification failed. Check the router clock
    first".

**8. Rollback** on the router (the backup holds the 2026-10-20 versions):

```sh
cd /root/router-script
take_lock() { n=0; until mkdir .ensure_network.lock 2>/dev/null; do [ "$n" -ge 120 ] && return 1; sleep 1; n=$((n+1)); done; }
take_lock && { for f in ensure_network.sh stop_tunnel.sh game_mode.sh refresh_blinkit_dns.sh login.sh rotate_tunnel_ip.sh; do cp -p "backup-batch4/$f" "$f.old" && mv "$f.old" "$f"; done; rmdir .ensure_network.lock; } || echo "lock busy: retry"
rm -f /tmp/router-script-tunnel-slow-count
```

The only new runtime state is that `/tmp` counter and log lines. The rollback
binary can stay; nothing uses it unless you roll back to it. For one finding,
run `git revert <commit>` on the Mac and redeploy that file. Several batch-4
commits touch nearby lines in `ensure_network.sh`, so a revert may need a
manual merge; the backup copy is the fastest emergency path.

| Finding | Commit(s) | Files | Revert order |
|---|---|---|---|
| F22 | `4b3c531` | `ensure_network.sh` | independent |
| F20 | `bf012b8`, `575bb11` | `ensure_network.sh`, tests | `575bb11` first |
| F14 | `99eab50` | `ensure_network.sh`, sandbox | before F06 (uses its helper) |
| F21 | `d0d18db` | `ensure_network.sh`, `login.sh` | independent |
| F28, F29, F30 | `113a1e1`, `a6ea218`, `bacac56` | `ensure_network.sh` (F29 also `game_mode.sh`) | independent |
| F13 | `172c205` | `refresh_blinkit_dns.sh` | independent |
| F19 | `3994808` | `game_mode.sh`, `rotate_tunnel_ip.sh` | independent |
| F27 | `9629f58` | `stop_tunnel.sh` | independent |
| F25 | `8164762` | `sync_to_router.sh`, README, wiki | before F23 |
| F23 | `f548383` | `sync_to_router.sh` | after F25 |

### 14.5 What I could not verify (batch 4)

- **Nothing in batch 4 ran on the router.** All behaviour comes from the
  sandbox under `dash` and macOS `bash --posix`, not BusyBox ash.
- **BusyBox specifics not yet run on the device:**
  - `test -nt` (F21). It is in POSIX.1-2024 and BusyBox's `test`.
  - `awk` `split()` in F22; `-v` and `index()` were verified on 10-20.
  - The ash `HUP` trap (F19).
  - `kill -HUP` success counting (F13).
- **F22 against the live list.** Only the 2026-08-01 snapshot was checked;
  the gate in §14.4 covers this.
- **F14's threshold against real latency.** Healthy probes took 69–75 ms on
  08-09. The live distribution of `time_total`, and so the false-warning
  rate, are unknown.
- **F12's correction (withdrawn).** The ownership check in §14.4 tested it
  live on 2026-10-22 and disproved it; see §15.
- **F19 against a real dropbear session:**
  - The test closes the pipes and sends SIGHUP to the process group. A real
    pty hangup gives EIO, not SIGPIPE, and which processes receive SIGHUP was
    not reproduced.
  - A job started without a tty gets no SIGHUP. Its next failed write exits
    under `set -e`, and `cleanup` should then complete. That is reasoned, not
    tested.
- **F23/F25 on the real link:** dropbear's `scp`, how long `sync` takes on
  the router's flash, and whether `/overlay` has room for the extra ~6 MB
  (it was 17 % used on 10-20) are unchecked, as is the rollback binary's
  presence there.
- **Deferred:** the Rust items (F10, F16–F18, and F27's `pending_pkt`) are
  unbuilt and untested.

## 15. Deployment record — 22 October 2026, 00:42–00:47 IST, and F12 reopened

### 15.1 Batch 4 deployment

You authorised SSH access for this deployment, and it followed §14.4. `.env`
and `config.json` were never read.

**Pre-flight (00:42), all read-only:**
- All six router scripts matched `41828c5` byte for byte.
- The rollback binary was already present (since 30 July), mode `0755`,
  with the Mac copy's SHA-256 (`e27256fe…`).
- `/overlay` was 17 % used (128 MB free) and `/tmp` 0 %. No lock was held,
  game mode was off, and the router and Mac clocks agreed to the second.
- WARP ran as PID 20421; uptime was 13.6 days. `ensure.log` showed one real
  WARP restart at 00:08 (both tunnel probes failed twice, then recovered) and
  three single probe failures that cleared on the re-check. The 10-20 code
  handled all of them as designed.
- **F22 gate:** passed on the live list, run by BusyBox `awk`. The list has
  14 entries: 4 upstreams, 3 Blinkit zones and 7 campus forwards. A control
  with two servers swapped failed, as it should.

**Staging and backup.**
- I staged the six scripts; the rollback binary needed none. The archive was
  built with `COPYFILE_DISABLE`, so it held no AppleDouble files.
- All six passed BusyBox `sh -n`, and their hashes matched the Mac.
- The backup is `/root/router-script/backup-batch4`: mode 700, six scripts
  matching `41828c5`, and the WARP PID.

**Step A** went in under the lock at 00:44:04: `stop_tunnel.sh`,
`game_mode.sh`, `refresh_blinkit_dns.sh`, `login.sh` and
`rotate_tunnel_ip.sh`. They are root-owned with mode `0755`, and their hashes
match. The 00:44:30 and 00:45:00 ticks passed, and the PID was unchanged.

**Step B** (`ensure_network.sh`) went in at 00:45:21, and its hash matches. A
manual run with the lock released passed in 2 s (exit 0) with no new
warnings, and the PID was unchanged. The ticks at 00:45:30, 00:46:00 and
00:46:30 passed.

**Step C** had nothing to install, since the identical binary was present.
The staging directory was removed.

**Post-deploy checks:**
- No DNS drift (F22), clock warnings (F21), slow checks (F14) or
  route-preference warnings (F07).
- F13 logged no change lines: the records had last changed on 2026-10-21 at
  05:36.
- BusyBox `test -nt` gave the right answer for three file pairs of known age.
- F08 still holds: rule 700 exists once, the chain has 5 rules, and the jump
  is the first PREROUTING rule.
- **Unexpected result.** The ownership check found 22 metric-1 host routes on
  `eth0` that no state file owns:
  - Two are the WARP endpoints, as expected.
  - The other 20 are CloudFront addresses in five groups of four, each group
    in one `/24`. That is the shape of `api3.blinkit.com`'s answers.
  - All 8 current Blinkit addresses were owned by the public route file.
  - The records predate the deploy, so the deploy did not create these
    routes. I stopped there, as instructed.

**Now verified on the router:** BusyBox `awk` `split()` (the F22 gate),
`test -nt` (F21), and the staged promotion of six scripts.
**Still unverified:**
- F19's HUP trap under ash.
- F13's PID count, since no change has happened yet.
- F14 under real latency.
- F23 and F25 over the real link (`sync_to_router.sh` was not run).

### 15.2 F12 reopened and fixed (`775bcd4`, not deployed)

**Why §14's correction was wrong.** It rested on a sandbox test of healthy
ticks, where the public refresher deletes a replaced address's route.
`refresh_blinkit_dns.sh` runs on every tick, but the public refresher runs only
after a healthy tunnel check. Two common states skip it:
- **WARP fallback.** `stop_tunnel.sh` deletes the public routes and the route
  file. The Blinkit script then re-adds its current routes on every tick, and
  no file records them.
- **Game mode.** `ensure_network.sh` exits before the optional route refresh.

A record set replaced in either state kept its routes until reboot. Two rarer
cases leak the same way:
- two quick changes, where dnsmasq had not yet reloaded on the first;
- a run that installed routes and then stopped before publishing.

**Fix.** The script now owns the records it publishes:
- It resolves every name before changing any route, so a run that cannot
  publish installs nothing.
- When the set changes, it computes the dropped addresses from the old hosts
  file and publishes the new set (HUP). It then removes the dropped
  addresses' routes, with the same spec they were installed with, except those
  another refresher's file still lists.
- On healthy ticks the public refresher still removes those routes, so timing
  there is unchanged.
- One log line counts the removals.

**Tests and checks.**
- Tests: two whole-pipeline tests (the WARP-down and game-mode paths) and
  three unit tests (the shared-route rule and unpublish-before-remove order,
  no removal while unchanged, and no routes from a run that stops early).
  All five fail before the fix.
- 77 tests pass under macOS `sh` and `dash`; the dash suite was also re-run on
  its own.
- Shellcheck findings are unchanged, and a healthy tick still costs 292
  processes.

**Invariants.** The script deletes only `/32`s it published itself, never
defaults, campus prefixes, NAT, DNS or Wi-Fi state.

**Residual risk.** If a CDN answer ever equalled a WARP endpoint address,
this refresher (like the public one today) could delete that endpoint's route.
Blinkit's answers are in other ranges, so this is theoretical.

**Still open.** Should the previous generation be kept for clients with cached
answers? F13's change rate will show.

### 15.3 Deploying the F12 fix and removing the 20 leaked routes

The fix cannot see the 20 routes, because no file records them, so the deploy
removes them once, explicitly. It needs your SSH authorisation, as before.

**0. Pre-flight (read-only).** The router's `refresh_blinkit_dns.sh` must
have the hash of `git show 6142896:refresh_blinkit_dns.sh | shasum -a 256`,
and no lock may be held.

**1. Stage, verify and back up**, as in §14.4 steps 1–2. Use one file, the
stage `.stage-f12` and the backup `backup-f12`.

**2. Promote under the lock**, using §14.4's `take_lock`/`promote`. The next
ticks must pass. The next Blinkit change logs "replaced-address routes
removed: …".

**3. Remove the leaked routes once.** This deletes only addresses that are on
the list recorded at 00:46 and still unowned at that moment, with the same
route spec:

```sh
cd /root/router-script
LEAKED="13.32.251.6 13.32.251.50 13.32.251.79 13.32.251.129 99.86.182.6 99.86.182.26 99.86.182.75 99.86.182.118 108.158.61.55 108.158.61.65 108.158.61.119 108.158.61.128 108.158.245.15 108.158.245.34 108.158.245.74 108.158.245.124 108.159.28.9 108.159.28.11 108.159.28.25 108.159.28.49"
GW="$(ip -4 route show default dev eth0 | awk '/via/ {print $3; exit}')"
owned() { cat /tmp/router-script-*-host-routes 2>/dev/null | grep -qxF "$1/32" || awk -v a="$1" '$1 == a { f = 1 } END { exit !f }' /etc/router-script/blinkit-hosts/hosts; }
[ -n "$GW" ] && for a in $LEAKED; do
    if owned "$a"; then echo "kept $a (owned again)"
    elif ip route del "$a/32" via "$GW" dev eth0 metric 1 2>/dev/null; then echo "removed $a"
    else echo "not present $a"; fi
done || echo "no WAN gateway: nothing removed"
```

Then re-run §14.4's ownership check. Only the two WARP endpoints should
remain. A flow that is using one of these addresses at that moment moves to
WARP and may reset once. Nothing needs restoring afterwards: every refresher
re-adds whatever it still needs on its next run.

**4. Rollback**, under the lock:
`cp -p backup-f12/refresh_blinkit_dns.sh refresh_blinkit_dns.sh.old && mv refresh_blinkit_dns.sh.old refresh_blinkit_dns.sh`.
The fix creates no new state.

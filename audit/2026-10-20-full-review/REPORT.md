# Full review of router-script — 20 October 2026

**Status: Phase 2 complete for the approved batches 1–3; nothing deployed.**
Eleven findings are fixed (F01, F02, F03, F04, F05, F06, F07 log-only, F08,
F09, F11, F15), one commit each, on branch `full-review-2026-10-20`. The
baseline is `2ba81fe` on `main`; `.env`, `config.json`, `logs/`,
`diagnostics/` and Cargo `target/` are excluded by `.gitignore`.

- **Outcome per finding:** §8.
- **Measured effect:** §9.
- **Invariant re-check:** §10.
- **Deployment checklist and rollback:** §11.
- **What I could not verify:** §12.

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
| F12 | Low | Confirmed | Correctness | `refresh_blinkit_dns.sh:34-37` | Blinkit `/32` routes are never removed |
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
    cleanup, and uses `\s` in BusyBox BRE.
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
| F12, F13, F14, F19, F20, F22, F23 | Deferred | — | Batch 4: not approved this round. |
| F21, F24, F25 | Deferred | — | Need your decision (see §7). |
| F26–F30 | Deferred | — | Batch 4. Only the wiki/README lines that the fixed items made inaccurate were updated, in the same commits (wiki contract). |

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

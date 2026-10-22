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
| F31 | Low | Confirmed (config); reachability unverified | Security | fw3 `INPUT`; `tunnel.sh` | New connections arriving on `tun0` reach SSH, the admin UI and DNS (found 2026-10-22, §16) |
| F32 | Low | Confirmed | Correctness | `tunnel.sh:212-261` (before `dcc7e10`) | Each start deleted every campus/public `/32` before re-resolving: live traffic moved to WARP on the reuse path, and failed lookups lost their routes (from 09-19 §6; §18) |
| F33 | Low | Confirmed (latent) | Robustness | `tunnel.sh:164` (before `e7131a4`) | WAN gateway taken from the first non-`tun0` default on any interface (§18) |
| F34 | Low | Confirmed | Failure handling | `tunnel.sh:222-261` (before `dcc7e10`) | One failed optional host route aborted the WARP start under `set -e` (§18) |
| F35 | Low | Confirmed (code) | Robustness (Rust) | `tunnel.rs` TUN writes (before `fc5b627`) | TUN write errors were ignored: a vanished device swallowed every downstream packet while the session looked healthy (09-19 §4; §19) |
| F36 | Low | Confirmed | Test coverage (Rust) | `tests/tunnel_mtu.rs` (before `5dd83dd`) | The MTU and pipeline tests exercised copies of the production code (09-19 §3; §19) |
| F37 | Low | Confirmed | Observability | `tunnel.sh` launch; `tunnel.rs` events | The client's output was discarded, so nothing recorded why a session ended (09-19 §3, A6; §19) |
| F38 | Low | Confirmed (fw3 source) | Failure handling | fw3 `restart`/`flush` | Every rule router-script adds was gone until the next tick after a firewall restart (A3; §19) |
| F39 | Low | Confirmed (sandbox, BusyBox) | Concurrency | `ensure_network.sh` lock (before `0d9284e`) | Live game-mode and rotation locks were taken over by age; an ownerless lock dated in the future was never taken over (09-19 §5, F21; §19) |
| F40 | Low | Confirmed (sandbox) | Deployment | `sync_to_router.sh` (before `58e02aa`) | Promotion trusted every transfer and could stop halfway; its lock had no live owner (09-19 §5; §19) |
| F41 | Low | Confirmed | Correctness | `game_mode.sh`, `configure_lan_ipv6.sh` (before `c394454`) | Game mode toggled `filter_aaaa`, which dnsmasq 2.85 ignores, and reloaded dnsmasq each time (known issue; §19) |
| F42 | Low | Confirmed (dash, BusyBox) | Concurrency | `game_mode.sh`, `rotate_tunnel_ip.sh` (before `b7ddaca`) | An SSH drop could still skip cleanup: a child killed by the hangup was reported on the closed terminal, and SIGPIPE killed the script (F19 follow-up; §19) |

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
| 09-19 §3 | Client stdout/stderr discarded, so no disconnect reasons | Fixed as F37 (A6); deployed 2026-10-23 (§19.9) |
| 09-19 §3 | MTU integration tests copy production logic | Fixed as F36; deployed 2026-10-23 (§19.9) |
| 09-19 §4 | ICMPv4 quote fixed at 28 bytes; TUN write errors ignored; CONNECT stream close ignored | TUN writes: F35; stream close and idle timeout: F16 (deployed 2026-10-23, §19.9). The 28-byte ICMPv4 quote is still open |
| 09-19 §5 | Non-transactional promotion; ownerless locks reclaimable after 180 s | Fixed as F40 and F39, with F42 for the hangup case; deployed 2026-10-23 (§19.9) |
| 09-19 §6 | `tunnel.sh` clears dynamic routes before resolving and doesn't share the refresh code | Fixed as F32–F34 (§18). The two scripts still resolve the names separately, but no longer conflict: `tunnel.sh` only adds. |
| 09-19 §2 | Loaded latency / SQM unmeasured | Still unmeasured; `measure_load_latency.sh` measures it (§19.7). F10 is the in-tunnel counterpart |
| google-wan.md | Firewall resets leave a gap until the next tick | F03 covered the FORWARD ACCEPTs; F38 closes the gap; deployed 2026-10-23 (§19.9) |
| known-issues | dnsmasq 2.85 ignores `filter_aaaa`, so game-mode AAAA filtering is ineffective | The dead toggle is gone (F41, deployed 2026-10-23, §19.9); game mode's IPv6 REJECT is what hides IPv6 |

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

**Status on 2026-10-23 (§19, deployed):** A1, A2, A3 (F38),
A4 (F39, F40), A6 (F37), A7 (F10, F16–F18) and A9 are done. A5 was done by F01
and F06, and A8 is `tests/sandbox.py`. A10 is still open.

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
| F10, F16, F17, F18 | **Deployed** 2026-10-23 01:02 | `ae4a630`, `084e40b`, `f7c5de3`, `21ba75e`, `6dd2346` | Deferred as batch 5, then done on 2026-10-22 once Rust builds were allowed (§19.1). F10 stays off by default until it is measured. |
| F12–F14, F19–F30 | See §14 (F12: §15) | — | Approved on 2026-10-21 as batch 4, with your decisions on F21, F24 and F25. Deployed on 2026-10-22; the F12 fix followed at 07:25 (§15). |
| F31 | **Deployed** 2026-10-22 08:39 | `3b3a183` | Found in the 2026-10-22 validation and deployed later that morning (§16). |
| F32–F34 | **Deployed** 2026-10-22 15:35 | `402b9ac` (tests), `e7131a4`, `dcc7e10` | Fixed test-first, then deployed and verified with a manual start (§18). |
| F27 (Rust half), F35–F42 | **Deployed** 2026-10-23 01:01–01:02 | §19.1–§19.2 | Carried over from the 09-19 audit or found on 2026-10-22, fixed test-first on `open-issues-2026-10-22`. |
| A1, A2, A9 | **Deployed** 2026-10-23 01:01 | `13f0642`, `fec160d`, `fec17de` | Shared defaults, stage-isolation tests, platform check (§19.2). |

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

## 15. Deployment records — 22 October 2026: batch 4 (00:42–00:47 IST) and the F12 fix (07:25–07:28)

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

### 15.2 F12 reopened and fixed (`775bcd4`, deployed at 07:25, §15.4)

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

### 15.4 F12 fix deployment record — 07:25–07:28 IST

You authorised SSH access for this deployment, and it followed §15.3. `.env`
and `config.json` were never read.

- **Pre-flight (07:25):**
  - The router's `refresh_blinkit_dns.sh` was the batch-4 version.
  - No lock was held, game mode was off, and WARP was still PID 20421.
  - Every tick since 00:46 had passed with no warnings.
  - The Blinkit records had not changed since 2026-10-21 05:36 (no F13
    lines), and the same 22 unowned routes were present.
- **Stage and backup:** one file. BusyBox `sh -n` passed and the hash matched
  `775bcd4`. The backup is `/root/router-script/backup-f12`: mode 700, the
  batch-4 version, and the WARP PID.
- **Promotion** under the lock at 07:25:36. The file is root-owned with mode
  `0755`, and its hash matches. The 07:26:00 and 07:26:30 ticks passed and
  the PID was unchanged. No Blinkit lines were logged, as expected while the
  records were unchanged.
- **One-time removal** at 07:27:03, running the §15.3 snippet extracted
  verbatim from this report: all 20 removed, none kept, none already absent.
- **Ownership check:** only the two WARP endpoints remain unowned.
  - None of the 20 is left in the table.
  - All 8 current Blinkit addresses are routed on `eth0`.
  - Both WARP endpoint routes are intact, and `1.1.1.1` still routes via
    `tun0`.
  - The 07:27:30 and 07:28:00 ticks passed and the PID was unchanged.
  - The staging directory was removed.
- **Not yet exercised in production:** the new cleanup acts only when the
  Blinkit records change. The next change should log "Blinkit DNS: records
  changed …" and then "replaced-address routes removed: …". Run §14.4's
  ownership check after it; expect only the WARP endpoints.
- **Rollback:** §15.3 step 4 (`backup-f12`). The removed routes need no
  restoring.

## 16. Final validation — 22 October 2026, 07:31–07:42 IST, and F31

You asked for a full check of the router after the deployments. Everything
was read-only, apart from one 10 MB download through WARP. `.env` and
`config.json` were checked for mode only.

### 16.1 Results

| Area | Result |
|---|---|
| System | Up 13 d 20 h; load 0.19 on 2 cores; 279 of 491 MB available; `/overlay` 16 %, `/tmp` 0 %; 307 of 16,384 conntrack entries |
| Temperature | CPU 68.5 °C; the fan is off by design until 76 °C (`glfan`) |
| Kernel (≈18 h of ring buffer) | No OOM, segfault, panic, hung task, conntrack overflow, flash error, watchdog or `eth0` link change |
| Syslog (00:15–07:32) | 134 `kern.err` lines, all MediaTek Wi-Fi driver notices (single TX failures, `CheckRxError`); 2 dnscrypt-proxy NOTICE lines logged at error level |
| WAN | Up on a 119 h lease; gateway 0 % loss, 0.8 ms; no interface errors |
| Routes | Every invariant holds: defaults via `tun0`, campus prefixes and WARP endpoints on `eth0` |
| WARP | `warp=on` for both families (BOM); HTTPS 71–74 ms; 0 % loss, 3.8 ms; 56.8 Mbps; queue empty when idle; no `tun0` errors |
| Direct path | Google 62–65 ms over `eth0`; portal reachable |
| DNS | All three upstreams answer; pins, split-horizon and Blinkit IPv4-only correct; server order and all DNS invariants intact; Google ipsets populated |
| Firewall and policy | WAN input admits only DHCP renewal, IGMP and port forwards; NAT, MSS, `FORWARD` rules, rules 690/700/710 and the game chain intact |
| Wi-Fi | Both radios up (IN, HE20/HE80); 8 clients on 5 GHz, −18 to −46 dBm |
| Health pipeline | 720 of 720 checks passed in 6 h, with no gap over 90 s; no lock, cooldown or warning markers |
| Integrity | 26 of the 28 deploy-set files (all but `.env` and `config.json`) match `2ae4750`; `README.md` and `PROJECT_CONTEXT.md` differ (docs were not deployed); secrets and all 30 snapshots are 0600. This row first said "28 of 30", a counting error |

**Benign observations:**
- The 56.8 Mbps download used 81 % of one core, so WARP is CPU-bound around
  60–70 Mbps on this hardware. That matches the 66 Mbps measured on 08-09, and
  it explains a momentary 87 % CPU reading taken during a client download.
- Campus filters ICMP beyond the gateway. Ping fails to 8.8.8.8, 1.1.1.1 and
  campus DNS, while DNS and HTTPS to them work.
- Short-lived zombie cron children come and go every minute (BusyBox `crond`
  reaps them on its next wake-up).
- The suspicious log readings were artifacts:
  - Undated `stop_tunnel.sh` lines come from the restarts on 19 Oct and at
    00:08 on 22 Oct.
  - `tunnel.log`'s last `[ERROR]` dates from 19 September.

### 16.2 F31 — new connections over `tun0` reach router services

**Evidence.** The router's `INPUT` chains (IPv4 and IPv6) have policy
`ACCEPT`. Zone dispatch exists only for `br-lan` and `eth0`, and `tun0` is in
no fw3 zone. Services listen on all addresses: SSH on 22, the GL.iNet UI on
80, 443, 8080 and 8443, and dnsmasq on 53, including on the tunnel addresses.
So a packet that reaches the router over the tunnel can open a connection to
any of them. The audit checked `FORWARD` (§1.1) but not `INPUT` for `tun0`.

**Exposure.** It is not known whether WARP ever delivers unsolicited inbound
traffic to a consumer client; it is not expected to. F31 is therefore a missing
safeguard (Low), not a known open door. After deployment, the new rule's packet
counter will show whether anything arrives.

**Fix (`3b3a183`).** The rule is `INPUT -i tun0 -m conntrack --ctstate NEW -j DROP`
for both IPv4 and IPv6.
- `tunnel.sh` adds the rules at start. It warns rather than failing a
  `set -e` start.
- `ensure_network.sh` re-checks them on every tick, before the game-mode exit,
  and restores them after a firewall reload. It logs, and never restarts WARP
  for them.
- `stop_tunnel.sh` keeps the rules: they match nothing without `tun0`, and the
  next start has no window without them.
- Replies, including ICMP errors for path MTU, are not NEW, so the router's
  own tunnel traffic is unaffected. Forwarded LAN traffic uses `FORWARD`.

**Tests and checks.**
- Six new tests, all failing before the fix:
  - the rule is present after a tick;
  - it is restored once after a simulated firewall reload;
  - it is kept in game mode;
  - a failure to add it warns but never restarts WARP;
  - only a missing rule is added;
  - `tunnel.sh` uses the same spec without risking the start.
- 83 tests pass under macOS `sh` (bash) and `dash`. Each suite was run on its
  own; see §16.4.
- Shellcheck findings are unchanged. A healthy tick costs 294 processes
  (+2: one `-C` per family).
- Invariants are unaffected: only `INPUT` changes.

### 16.3 Deploying F31 (done on 22 October, §16.5)

**0. Pre-flight (read-only).**
- The router's `tunnel.sh` and `ensure_network.sh` must match
  `git show 2ae4750:<file> | shasum -a 256`.
- No lock may be held.
- Record that the rule is absent:
  `iptables -C INPUT -i tun0 -m conntrack --ctstate NEW -j DROP; echo $?`
  (and the same for `ip6tables`) prints 1.

**1. Stage, verify and back up** both files, as in §14.4 steps 1–2. Use the
stage `.stage-f31` and the backup `backup-f31`.

**2. Promote both files under the lock**, with §14.4's `take_lock`/`promote`.
- `ensure_network.sh` adds the rules on its first tick and logs "Added the
  missing iptables rule dropping new inbound connections on tun0." (and the
  same for ip6tables).
- `tunnel.sh` takes effect at the next WARP start.

**3. Verify.**
- Both `-C` checks print 0.
- The next ticks pass, and the WARP PID is unchanged.
- LAN browsing works, and the health probes through `tun0` keep passing.
- After a day, `iptables -L INPUT -v -n | grep tun0` (and `ip6tables`) shows
  whether any unsolicited connection actually arrived.

**4. Rollback.**
- Restore both files from `backup-f31` under the lock.
- Remove the rules:
  `while iptables -C INPUT -i tun0 -m conntrack --ctstate NEW -j DROP 2>/dev/null; do iptables -D INPUT -i tun0 -m conntrack --ctstate NEW -j DROP; done`
  (and the same for `ip6tables`).

### 16.4 Testing note

Twice today (the F12 and F31 runs), the scratchpad runner that starts the
`sh` and `dash` suites in parallel produced byte-identical output files, with
the same duration to the millisecond. That is implausible for two independent
runs, and the cause is unexplained. Both times the suites were re-run on their
own:
- F12: dash 144.7 s;
- F31: `sh` 154.3 s and dash 152.6 s.

They passed each time. Treat that runner's parallel output as unverified until
the cause is found.

### 16.5 F31 deployment record — 08:39–08:42 IST

You authorised this deployment ("go ahead deploy any other fixes you want
to"), and it followed §16.3. `.env` and `config.json` were never read.

**Scope.** F31 (`tunnel.sh` and `ensure_network.sh`), plus the two doc files
that carry the F25/F26 documentation fixes (`README.md`, `PROJECT_CONTEXT.md`).
No other committed fix was undeployed. The Rust items stay source-only, as the
brief requires.

**Pre-flight (08:39):**
- Both scripts matched `2ae4750`, and the docs were mode `0644`.
- No lock was held, game mode was off, and WARP was PID 20421.
- Every check since 07:28 had passed.
- Both rule checks returned 1, confirming the rules were absent.

**Staging and backup.**
- I staged four files. Both scripts passed BusyBox `sh -n`, and all hashes
  matched HEAD (`17bd74d`).
- The backup is `/root/router-script/backup-f31`: mode 700, the four files
  and the WARP PID.

**Promotion** went in under the lock at 08:39:43. Scripts are `0755` and docs
`0644`, all root-owned, and every hash matches.
- The 08:40:00 check added both rules (one log line for each family) and
  passed.
- The 08:40:30 check added nothing and passed.
- Each rule exists once, first in `INPUT`.

**Unaffected:**
- `warp=on` for both families.
- HTTPS through `tun0` took 71–109 ms, and ping through it had 0 % loss.
- dnscrypt-proxy and dnsmasq answer.
- LAN forwarding is normal: 222 packets out in 10 s across 266 LAN flows.
- The WARP PID was unchanged; WARP was not restarted.

**State after the deploy:**
- By 08:42 the rules had dropped 0 packets. Read the counters after a day:
  `iptables -L INPUT -v -n | grep tun0` (and the same for `ip6tables`).
- All 28 deploy-set files now match HEAD, and the staging directory was
  removed.
- `tunnel.sh`'s copy of the rule takes effect at the next WARP start.

**Rollback:** §16.3 step 4.

## 17. Cleanup — 22 October 2026, 08:44–08:52 IST

You asked me to delete the deployment backups, and then to clean up the project
on the router and the Mac. Only non-live files were removed. No live script,
data file, secret, log or snapshot was touched, and `.env` and `config.json`
were never read.

### 17.1 Router

**Result.** The directory went from 33.3 MB (8 folders, 53 files) to 21.2 MB.
It now holds exactly the 28 deploy-set files, `.env`, `config.json`, `logs/`
and `diagnostics/`. `/overlay` dropped from 16 % to 11 % used.

**Removed:**
- the four deployment backups (`backup-20261020`, `backup-batch4`,
  `backup-f12`, `backup-f31`). Every script copy matched a git commit; the two
  old doc copies were strict subsets of the 10-20 baseline docs;
- 17 August `*.rollback-*` script copies and two old `usque-rs.rollback-*`
  binaries;
- five older backup folders and one staging folder, dated 09-19 to 10-08;
- the router's stale copies of the Mac-side `sync_to_router.sh` and
  `sync_from_router.sh`;
- a `.DS_Store`, and an old `.env` copy, which was deleted unread.

**Checks before deleting.** Nothing live referenced these files: no script,
crontab, init file or UCI entry. The two UCI matches were LuCI's own
apply-rollback keys. I hashed every file against git history: 27 were already
in git.

**Archive.** The other 27 are in a private archive on the Mac, outside the repo:
`~/router-script-archive/router-leftovers-2026-10-22.tar.gz` (mode 0600,
3.0 MB). It was extracted and found byte-identical, and a manifest of paths and
hashes sits beside it. Delete it whenever you like.

**After the cleanup.** The 08:51:00 and 08:51:30 checks passed, WARP kept PID
20421, and both cron entries are intact.

### 17.2 Mac

Removed a `.DS_Store` and the `__pycache__` folders under `tests/` and
`tools/`. The tracked tree is unchanged.

Left in place on purpose, all ignored by git:
- `.env` and `config.json`;
- your `.claude/settings.local.json`;
- `logs/` and `diagnostics/`, which the report and wiki cite as evidence;
- `usque-rs-optimized/target/`, 3.3 GB of Rust build output. Recreating it
  needs Docker and a full build, so whether to delete it is your call.

### 17.3 Rolling back now that the backups are gone

The rollback commands in §11, §14.4, §15.3 and §16.3 copy from `backup-*`
folders that no longer exist. Use the previous versions from git instead:

| Deployment | Files | Previous version |
|---|---|---|
| 2026-10-20 (§13) | `diagnose.sh`, `collect_diagnostics.sh`, `login.sh`, `google_wan_policy.sh`, `rotate_tunnel_ip.sh`, `ensure_network.sh` | `2ba81fe` |
| Batch 4 (§15.1) | `ensure_network.sh`, `stop_tunnel.sh`, `game_mode.sh`, `refresh_blinkit_dns.sh`, `login.sh`, `rotate_tunnel_ip.sh` | `41828c5` |
| F12 fix (§15.4) | `refresh_blinkit_dns.sh` | `6142896` |
| F31 (§16.5) | `tunnel.sh`, `ensure_network.sh` | `2ae4750` |
| F32–F34 (§18.5) | `tunnel.sh` | `49dfedd` |
| Open issues (§19.9) | the 20 replaced files, including `usque-rs`; remove the 6 new files | `72e3abd` |

To roll back:
1. On the Mac, export the files into an empty folder:
   `git archive <commit> <files> | tar -x -C <folder>`.
2. Stage, verify and promote them from that folder, exactly as in §14.4.
3. Undoing F31 also needs its rules removed (§16.3 step 4).

The binary rollback (`usque-rs-upstream-v0.1.0`) is unaffected.

## 18. `tunnel.sh` start path (F32–F34) — 22 October 2026, deployed (§18.5)

You asked me to write up the three open start-path issues from the 09-19
audit (§4) and fix them test-first, without deploying.

### 18.1 Findings

- **F32 — host routes deleted before resolving.** Each run deleted every
  campus and public `/32` listed in the state files, and truncated the files,
  before re-resolving the 16 names (each lookup can take 3 s).
  - The automated callers (the health check's restart, rotation, the sync
    restart, game-mode-off) run `stop_tunnel.sh` first. `tun0` is then not
    yet the default, so nothing is misrouted.
  - When a running client is reused, as in a manual `./tunnel.sh` repair,
    `tun0` is already the default. Those hosts then went over WARP until their
    names resolved again, and flows NATed on `eth0` broke.
  - On every path, a name that failed to resolve lost its route until a later
    refresh. That defeated the health check's rule of keeping routes during a
    partial DNS outage.
- **F33 — gateway from any interface.** The script took the first other
  default from any interface:
  `ip route show default | grep -v "dev tun0" | head -n 1 | awk '/default/ {print $3}'`.
  For a default without `via`, it printed a device name instead. A second
  uplink (wwan, USB tethering) listed first would make every
  `via GW dev eth0` route fail and abort the start (see F34). This is latent:
  this router has one WAN.
- **F34 — optional routes could abort the start.** The resolution loops ran as
  `nslookup | awk | while` under `set -e`. One failed `ip route replace` in
  the loop ended the whole WARP start through the revert trap. Causes include
  a bad gateway, a WAN flap mid-start, or an unroutable answer. The health
  check then counted a failed restart and fell back to direct WAN with a
  cooldown.
- **Not an issue.** The awk filter does not pick up the DNS server's own
  address line: the router's BusyBox prints it as `Address:	127.0.0.1#53`
  (checked in the local snapshots).

### 18.2 Fix

- **F33 (`e7131a4`).** The gateway is now the `via` of
  `ip -4 route show default dev eth0`, as in `ensure_network.sh` and
  `refresh_blinkit_dns.sh`.
- **F32 and F34 (`dcc7e10`).** One `add_host_routes` function replaces both
  loops.
  - It installs routes for whatever resolves now and appends them to the same
    state files, never truncating them.
  - A route that cannot be installed only warns.
  - The health check's refresher stays the only remover: it removes stale
    routes once every name resolves, and never one that another refresher
    lists.
  - The campus-prefix and WARP-endpoint routes stay mandatory, so their
    failure still stops the start.
- **Effect.** After a start, a stale host route can remain until the next
  healthy check (normally within 30 s) or until `stop_tunnel.sh`. `tunnel.sh`
  is 16 lines shorter.

### 18.3 Tests and checks

- `402b9ac` makes `tunnel.sh` testable: a dummy client and a live PID take it
  through the "reuse the running client" branch. It also fixes two stub cases
  that exited 1 whenever their flag was unset; one of them failed `tunnel.sh`
  at every start.
- There are six new tests, and each finding's tests failed before its fix:
  - the baseline start;
  - F33: a competing default route on another interface;
  - F32: no host route removed, routes kept after failed lookups, and the
    health check still removing stale routes after a start;
  - F34: a failed host route not aborting the start.
- At every commit all tests pass under macOS `sh` and `dash`, each suite run on
  its own: 84, then 85, then 89 tests. Shellcheck findings are unchanged.
- Invariants: only `tunnel.sh` changed. Defaults, campus prefixes, WARP
  endpoints, NAT, MSS, DNS, IPv6 and secrets handling are untouched, and the
  start still fails for a mandatory route.

### 18.4 Deploying (done on 22 October, §18.5)

Only `tunnel.sh` changes, and it runs only when WARP starts.

0. **Pre-flight.** The router's `tunnel.sh` must match
   `git show 49dfedd:tunnel.sh | shasum -a 256`, and no lock may be held.
1. **Stage and verify** as in §14.4 steps 1–2, using the stage `.stage-f32`.
   No backup folder is needed: the previous version is in git (`49dfedd`).
2. **Promote under the lock** with `take_lock`/`promote`. Nothing runs the new
   file until the next WARP start.
3. **Verify (optional).** A manual `./tunnel.sh` while WARP runs now takes the
   reuse path safely.
   - It also restarts odhcpd and rebuilds the game chain, a brief blip for
     LAN IPv6 and for new game sessions.
   - Check `logs/tunnel.log` for "[SUCCESS] Full tunnel active" and for no
     `ip route del` of host routes.
   - Otherwise, the next natural start exercises it.
4. **Rollback.** Stage `tunnel.sh` from `49dfedd` (§17.3).

### 18.5 Deployment record — 15:34–15:37 IST

You authorised this deployment. It followed §18.4, including the optional
verification run. `.env` and `config.json` were never read.

**Pre-flight.**
- The router's `tunnel.sh` matched `49dfedd`.
- No lock was held, game mode was off, and WARP was PID 20421.
- There had been no non-routine health-check line since 08:51.

**Staging.** I staged the new `tunnel.sh` with the previous version beside it
(from git `49dfedd`), so a rollback would be a local copy. Both passed BusyBox
`sh -n`. The new file matched the branch, and the previous copy matched both
git and the live file.

**Promotion** under the lock at 15:35:20; the hash matches.

**Dry run, read-only.** On the router, the new gateway lookup returned
`10.1.40.250`. The exact resolution pipeline resolved all 5 campus names and
all 11 public names.

**Verification run** at 15:36:05: `tunnel.sh` through its reuse path, under
the lock.
- It exited 0 with "[SUCCESS] Full tunnel active", and no host route failed.
- Nothing was removed: the campus routes stayed at 5, the public routes at 37,
  and the metric-1 host routes at 45.
- WARP kept PID 20421. Both `tun0` defaults, rule 700, the game chain (5
  rules, jump first) and both F31 drop rules are intact.
- The 15:36:30 check passed.

**Wrap-up.** The staging directory was removed. All 28 deploy-set files match
the branch, and the directory holds only its 32 live entries.

**Rollback:** stage `tunnel.sh` from `49dfedd` (§17.3).

## 19. Open issues fixed on 22 October 2026, deployed on 23 October (§19.9)

You asked me to tackle the open issues and the optional housekeeping, and
allowed changes to the Rust binary. With your permission, it was deployed on
23 October following the checklist in §19.6 (record: §19.9). Each finding is one commit, and its
test failed before the fix.

### 19.1 Rust client (`usque-rs`)

This covers the audit's A7, the Rust half of F27 and two items carried over
from the 09-19 audit.

| ID | Commit | Change |
|---|---|---|
| F27 (Rust) | `b52cb99` | The never-set `pending_pkt` and its dead replay block are gone. |
| F35 | `fc5b627` | **From 09-19 §4.** Both TUN writes ended in `.ok()`, so a vanished device swallowed every downstream packet while the session looked healthy. A failure now counts as a drop, and 32 in a row end the session. |
| F18 | `6dd2346` | The key and certificate PEM files are deleted as soon as quiche loads them. SIGTERM skips destructors, so each stop probably left the private key in `/tmp`. |
| F17 | `21ba75e` | Backoff depends on how long the session was connected. Ten seconds or more counts as stable: a clean close reconnects at once, and a failure restarts at 1 s. A shorter session keeps doubling the delay to 30 s, so a server that accepts and then drops sessions cannot cause a reconnect storm. |
| F16 | `f7c5de3` | The idle timeout is three keepalives (90 s), and a timed-out session ends as an error. A finished CONNECT stream ends the session cleanly; a reset ends it as an error carrying the code. |
| F36 | `5dd83dd` | **From 09-19 §3.** The 19 MTU and pipeline tests ran against copies of the production code. They are now unit tests of the real functions, and a mutation check (no TTL decrement) makes them fail. |
| F10 | `ae4a630`, `084e40b` | `--tun-backpressure N` pauses TUN reads while N datagrams wait to be sent. `tunnel.sh` passes it only when `WARP_TUN_BACKPRESSURE` is set. **It is off by default.** A TUN device may drop at its ring instead of pushing back on the qdisc, so the benefit is unproven until measured (§19.7). |
| F37 | `9549947` | **A6.** With `--syslog`, the client sends these events to `/dev/log`, where `logread -e usque-rs` shows them: connecting, connected, the end of each session with its error, the reconnect delay, and fatal errors. The socket never blocks, writes to stderr never panic, and the per-second status line is drawn only on a terminal. `tunnel.sh` passes `--syslog` only when the binary lists it, so the rollback binary still starts. |

**Checks.** The pinned toolchain image is the one that reproduced the
deployed binary byte for byte (rustc 1.95.0).
- 76 unit and 4 integration tests pass in it.
- `cargo fmt --check` and `clippy --all-targets -D warnings` are clean,
  including the pedantic, nursery and cargo lint groups.
- The candidate binary is described in §19.5.

### 19.2 Shell scripts

| ID | Commit | Change |
|---|---|---|
| F38 | `643078a` | **A3.** `fw3 restart` and `fw3 flush` (also `/etc/init.d/firewall stop`) flush every chain and delete every user chain, so all of router-script's rules were gone until the next tick. `fw3 reload` keeps them, because it deletes only rules tagged `!fw3` (checked in firewall3's source). `firewall_hook.sh` is now an fw3 script include, `firewall.router_script`, with `reload 1`. After fw3 rebuilds, and if a WARP client is running, it starts a health check, which already restores every rule involved. The check runs detached and 2 s later, because fw3 holds its lock until its includes return. `install_firewall_hook.sh` registers the include, and `bootstrap_router.sh` runs it. |
| F39 | `0d9284e` | **A4.** One helper, `lock.sh`, serves every lock holder. The owner file records PID, process start time, uptime at acquisition and script name. The lock is taken over when its owner is dead, when its PID now belongs to another process, or after 600 s of uptime (a hung owner). Before this, ensure took over a live game-mode or rotation lock by clock age. An ownerless lock dated in the future (from a reboot before NTP syncs) was never taken over, so every tick skipped. Takeovers are serialized by a second directory. The lock path is unchanged. |
| F40 | `58e02aa` | **A4.** `sync_to_router.sh` stages first, with a SHA-256 manifest. `promote_staged.sh` then runs on the router as one process. It verifies every staged file and promotes nothing on a mismatch. It takes the lock as a live owner, stops the tunnel, and moves the files with sourced helpers first. It ignores SIGHUP and SIGPIPE, so a dropped SSH connection cannot stop it halfway. |
| F42 | `b7ddaca` | **New.** F19's HUP traps were incomplete. When a foreground child that shares the closed terminal dies of the hangup, dash and BusyBox ash report "Hangup" on that terminal. The write raises SIGPIPE, which kills the script before any trap runs. Over non-pty SSH, two scripts were affected: a rotation dropped during its WARP probe never restored the old registration and left `config.json.previous`, which blocks later rotations; game mode left the lock and a half-applied policy. Both scripts now trap PIPE as well. The failure was reproduced, and the fix confirmed, under dash and BusyBox 1.33.1. |
| F41 | `c394454` | **Known issue closed.** Game mode toggled `filter_aaaa` and reloaded dnsmasq each time, but dnsmasq 2.85 ignores the option, so nothing was ever filtered. IPv6 is in fact hidden by game mode's REJECT: ICMPv6 port unreachable is a hard error, so clients fall back to IPv4 at once. `filter_aaaa` is now 0 in every mode, and the LAN IPv6 check expects 0 in game mode too. |
| A2 | `fec160d` | Already achieved by F02: LAN IPv6 and Google policy failures only log. New tests pin this; no code changed. |
| A9 | `fec17de` | A check that runs once per boot, after the WAN checks. It covers the required tools (`conntrack` optional), the radio sections, a WAN default metric that would beat WARP's 5 (skipped in game mode), and the fw3 include. It logs "Platform check passed." or one WARNING naming every problem, and changes nothing. |
| Tool | `823d8c7` | `measure_load_latency.sh`; see §19.7. |
| A1 | `13f0642` | `defaults.sh` holds the 39 defaults that 2 to 9 scripts each defined: 125 copies, all still equal, plus 6 inline copies of the same values. 17 scripts source it after `.env`, so `.env` still wins. Tests pin every value, and fail when a default reappears in two scripts. |

A5 (diagnostics policy) was done by F01 and F06, and A8 is
`tests/sandbox.py`. A10 (mark-bit allocation) is docs-only and still open.

### 19.3 Tests and checks

- **Shell tests.** There were 89 tests at the start of the day; there are 133
  now. For every commit, both suites ran in full on their own copy of the
  tree, once under macOS `sh` and once under `dash` as `sh`.
- **The §16.4 oddity.** It has a likely cause: `tests/sandbox.py` runs scripts
  under dash whenever dash is installed, so both "modes" exercised dash inside
  the sandbox.
- **Real BusyBox.** These ran in a container with BusyBox 1.33.1 ash and a
  real `/proc` (the router has 1.33.2):
  - 20 lock checks: identity, takeovers, waiting, and 20 contended races,
    each with exactly one winner;
  - the promotion, with a good stage and a corrupt one;
  - the hangup cases behind F42.
- **Mutation checks.**
  - Without its PIPE trap, the promotion stops before moving anything.
  - With the syslog formatting and delivery stubbed out, the event tests fail.
- **Shellcheck.** Findings are unchanged except for the expected "not
  following" notes (SC1091) for the new sourced helpers, and one SC2153
  note, which is marked where it applies.
- **Cost.** A healthy tick spawns 295 processes, against 294 on `main`. Recording the
  lock owner adds two `awk` calls, and reading the owner file no longer needs `cat`.

### 19.4 Invariants

- **Unchanged:**
  - routes and DNS: defaults through `tun0`; campus prefixes, the WARP
    endpoints and the campus `/32`s on `eth0`; DNS strict order and the
    campus forward list;
  - IPv6 and DNS settings: `ra_default=2`, `block_ipv6=false`, ULA with
    NAT66, MSS clamping;
  - Wi-Fi: country IN, HE20 and HE80;
  - files and rollback: secret file modes and atomic registration writes;
    the rollback binary;
  - bounded recovery. The platform check and the hook only log or trigger
    the existing check, and the lock's 600 s hold limit adds a bound where
    there was none.
- **`filter_aaaa=0`** now also holds in game mode.

### 19.5 Candidate binary (`688e216`)

- **Build.** Built twice from clean in the pinned image; the two builds are
  byte-identical: sha256 `0d1496d353d952b814948cf6479521603a4e0c97de0b6437fda1aacf65a78fef`, 6,035,280 bytes. `--help` lists `--syslog`
  and `--tun-backpressure`.
- **Deployed** on 23 October (§19.9); it replaced the tracked `usque-rs`.
- **Rollback.** `usque-rs-upstream-v0.1.0` stays as the rollback binary, and
  the deployed `1ee312fc…` stays in git (`main`).

### 19.6 Deployment checklist (done on 23 October, §19.9)

**What changes.** Twenty files are replaced and six are new. `.env`,
`config.json`, `paths.sh`, the data files, `install_cron_pipeline.sh`,
`download_emergency_diagnostics.sh` and the rollback binary are untouched.
- **Replaced:** `bootstrap_router.sh`, `collect_diagnostics.sh`,
  `configure_dns.sh`, `configure_lan_ipv6.sh`, `configure_wifi.sh`,
  `diagnose.sh`, `dns_flow.sh`, `ensure_network.sh`, `game_mode.sh`,
  `google_wan_policy.sh`, `login.sh`, `monitor_game_network.sh`,
  `refresh_blinkit_dns.sh`, `rotate_logs.sh`, `rotate_tunnel_ip.sh`,
  `stop_tunnel.sh`, `tunnel.sh`, `PROJECT_CONTEXT.md`, `README.md` and
  `usque-rs`.
- **New:** `defaults.sh`, `lock.sh`, `firewall_hook.sh`,
  `install_firewall_hook.sh`, `promote_staged.sh` and
  `measure_load_latency.sh`.

**Two rules for this deployment only.**
- **Take the lock the old way.** Until its file is replaced, the cron health
  check runs the old lock code. That code treats an owner file it cannot
  parse as stale, so it would take over a lock held by `promote_staged.sh`.
  Hold the lock with an ownerless `mkdir` instead; old and new code both
  respect that for 180 s. Later deployments can use `sync_to_router.sh`.
- **Turn game mode off first** (F41). A router left at `filter_aaaa=1` would
  get one LAN IPv6 repair, which reloads the LAN.

**0. Pre-flight (read-only, on the router).**

```sh
cd /root/router-script
sha256sum bootstrap_router.sh collect_diagnostics.sh configure_dns.sh configure_lan_ipv6.sh configure_wifi.sh diagnose.sh dns_flow.sh ensure_network.sh game_mode.sh google_wan_policy.sh login.sh monitor_game_network.sh refresh_blinkit_dns.sh rotate_logs.sh rotate_tunnel_ip.sh stop_tunnel.sh tunnel.sh PROJECT_CONTEXT.md README.md usque-rs
ls -d .ensure_network.lock .stage-oi 2>/dev/null; [ ! -f /tmp/router-script-game-mode ] && echo "game mode off"
uci -q get dhcp.@dnsmasq[0].filter_aaaa; uci -q show firewall.router_script || echo "no include yet"
pidof usque-rs; df -h /overlay /tmp
grep -h 'Blinkit DNS: records changed' logs/ensure.log* logs/tunnel.log* 2>/dev/null | cut -c1-16 | sort    # §19.7
```

- **Hashes.** Every hash must equal `git show main:<file> | shasum -a 256` on
  the Mac (`usque-rs`: `1ee312fc…`).
- **State.** Expect no lock and no stage, game mode off, `filter_aaaa` 0 and
  no include yet.
- **Stop if** anything differs.

**1. Stage from the Mac** (file names written out; zsh does not split
variables):

```sh
cd /Users/atharva/projects/router-script
tar -cf - defaults.sh lock.sh firewall_hook.sh install_firewall_hook.sh promote_staged.sh measure_load_latency.sh bootstrap_router.sh collect_diagnostics.sh configure_dns.sh configure_lan_ipv6.sh configure_wifi.sh diagnose.sh dns_flow.sh ensure_network.sh game_mode.sh google_wan_policy.sh login.sh monitor_game_network.sh refresh_blinkit_dns.sh rotate_logs.sh rotate_tunnel_ip.sh stop_tunnel.sh tunnel.sh PROJECT_CONTEXT.md README.md usque-rs | ssh -o BatchMode=yes root@192.168.8.1 'umask 077; cd /root/router-script && mkdir .stage-oi && tar -xf - -C .stage-oi && cp -p usque-rs .stage-oi/usque-rs.previous'
shasum -a 256 defaults.sh lock.sh firewall_hook.sh install_firewall_hook.sh promote_staged.sh measure_load_latency.sh bootstrap_router.sh collect_diagnostics.sh configure_dns.sh configure_lan_ipv6.sh configure_wifi.sh diagnose.sh dns_flow.sh ensure_network.sh game_mode.sh google_wan_policy.sh login.sh monitor_game_network.sh refresh_blinkit_dns.sh rotate_logs.sh rotate_tunnel_ip.sh stop_tunnel.sh tunnel.sh PROJECT_CONTEXT.md README.md usque-rs
```

The previous binary is copied into the stage on the router, so a binary
rollback is a local copy.

**2. Verify on the router.**

```sh
cd /root/router-script
for f in .stage-oi/*.sh; do sh -n "$f" || echo "SYNTAX FAIL $f"; done
sha256sum .stage-oi/*      # equal to the Mac's list; usque-rs.previous is 1ee312fc...
.stage-oi/usque-rs nativetun --help | grep -c -e --syslog -e --tun-backpressure    # 2
take_lock() { n=0; until mkdir .ensure_network.lock 2>/dev/null; do [ "$n" -ge 120 ] && return 1; sleep 1; n=$((n+1)); done; }
promote() { for f in "$@"; do cp ".stage-oi/$f" "$f.new" && chmod 755 "$f.new" && mv "$f.new" "$f"; done; }
```

**3. Promote the scripts.** This uses the ownerless lock, puts the helpers
first and registers the include before releasing the lock:

```sh
take_lock && {
  promote defaults.sh lock.sh
  promote firewall_hook.sh install_firewall_hook.sh promote_staged.sh measure_load_latency.sh bootstrap_router.sh collect_diagnostics.sh configure_dns.sh configure_lan_ipv6.sh configure_wifi.sh diagnose.sh dns_flow.sh ensure_network.sh game_mode.sh google_wan_policy.sh login.sh monitor_game_network.sh refresh_blinkit_dns.sh rotate_logs.sh rotate_tunnel_ip.sh stop_tunnel.sh tunnel.sh
  cp .stage-oi/PROJECT_CONTEXT.md .stage-oi/README.md .
  sh install_firewall_hook.sh
  sync
  rmdir .ensure_network.lock
} || echo "lock busy: nothing changed, retry"
```

**4. Verify the scripts** (WARP keeps running):
- **Next tick (≤ 30 s).** `tail -n 5 logs/ensure.log` shows "Platform check
  passed." (or one WARNING to read) and "Health check passed.".
- **Include.** `uci show firewall.router_script` shows the type `script`,
  the hook's path and `reload '1'`.
- **No disruption.** WARP keeps its PID. The `tun0` drop rules, NAT and
  FORWARD rules are unchanged.

**5. Restart WARP on the new binary.** Expect an outage of 5–25 s:

```sh
take_lock && {
  sh stop_tunnel.sh
  cp .stage-oi/usque-rs usque-rs.new && chmod 755 usque-rs.new && mv usque-rs.new usque-rs
  sh tunnel.sh
  rmdir .ensure_network.lock
}
```

- **Start.** `logs/tunnel.log` shows "[SUCCESS] Full tunnel active", with no
  "cannot log connection events" warning.
- **Events.** `logread -e usque-rs` shows "Config loaded", "[connecting]" and
  "[connected] MASQUE tunnel established".
- **Binary.** `sha256sum usque-rs` prints `0d1496d3…`, the candidate (§19.5).
- **Health.** The next ticks pass, and the Cloudflare trace through `tun0`
  reports `warp=on`.
- **Stop rule.** If the start fails, restore the binary at once, then report:

  ```sh
  take_lock && { sh stop_tunnel.sh; cp .stage-oi/usque-rs.previous usque-rs.new && chmod 755 usque-rs.new && mv usque-rs.new usque-rs; sh tunnel.sh; rmdir .ensure_network.lock; }
  ```

**6. Optional: exercise the hook.** Run `fw3 reload`. It keeps
router-script's rules and runs the include. Within a few seconds,
`logs/ensure.log` shows "Starting health check: the firewall was rebuilt."
and then "Health check passed.". A reload rebuilds only fw3's own chains,
which also happens on every WAN DHCP event. For a few milliseconds the
chain policies are DROP.

**7. Optional: measure loaded latency** (§19.7).

**8. Wrap up.**
- Remove `.stage-oi` once the new binary is accepted.
- Check that all deploy-set files match the branch.
- Merge the branch into `main`, so `main` matches the router again.

**Rollback.**
- **Scripts.** On the Mac, export the previous versions with
  `git archive main <files> | tar -x -C <folder>`. Stage them and promote
  them under an ownerless lock, as above. Then delete the six new files: the
  old scripts do not source them.
- **Include.** Run
  `uci delete firewall.router_script && uci commit firewall`.
- **Binary.** Use the stop-rule command in step 5.

### 19.7 Loaded latency (F10) and Blinkit route retention

**F10 measurement.** Run this after step 5, with your permission. It takes
about five minutes and includes two short WARP restarts. Each run saturates
the uplink and then the downlink for about 20 s, which other LAN users will
notice.
1. **Baseline.** Run `sh measure_load_latency.sh 20`. It appends idle,
   upload and download lines to `logs/latency.log`.
2. **With backpressure.**
   - Restart WARP with backpressure on:
     `take_lock && { sh stop_tunnel.sh; WARP_TUN_BACKPRESSURE=64 sh tunnel.sh; rmdir .ensure_network.lock; }`
   - Measure again. The log line names `--tun-backpressure 64`.
   - Optionally, try 256 the same way.
3. **Restore the default.** Run the same restart without the variable. A
   healthy client is never restarted by the health check, so the setting
   stays until you restart.

**Decision rule.**
- **Adopt N as the default only if:**
  - the upload phase's median round trip falls clearly, by a third or at
    least 50 ms;
  - upload throughput stays within about 10 %;
  - the download phase is unchanged;
  - and this holds in two runs, since campus load varies.
- **Otherwise,** keep it off.

**Blinkit route retention (open since §15.2).** The question is whether a
replaced address's route should stay for a while, for clients that cached the
old answer. Pre-flight step 0 counts F13's "records changed" lines. They show
how often the answers change; F13 has logged since 22 October 00:42.
- **Changes are rare** (a few a day): immediate removal is fine. A stale
  cached answer only lasts its DNS TTL.
- **Changes come several times an hour:** keep the previous generation's
  routes for an hour. That would be a small change to
  `refresh_blinkit_dns.sh`.

### 19.8 What I could not verify

- **Since checked on the router (§19.9):** logd accepts the client's
  `<priority>tag[pid]: message` datagrams, and the hook runs after a real
  `fw3 reload`. The new client's behaviour over days (idle timeouts, backoff,
  write failures) is not yet observed.
- **F38.** The fw3 behaviour comes from upstream firewall3, not from the
  GL.iNet build. I don't know whether GL.iNet's own includes remove foreign
  rules on a plain reload; the hook runs then too, so they would still be
  restored.
- **BusyBox.** The tests ran BusyBox 1.33.1 from a container. The router's
  1.33.2 may be configured with different applets.
- **F16 versus Cloudflare's timeout.** It is unknown how the 90 s idle
  timeout interacts with Cloudflare's own idle timeout; QUIC uses the shorter
  of the two.
- **F10** is unmeasured (§19.7).
- **Old key files.** PEM files that earlier stops left in `/tmp` are not
  checked. `/tmp` is RAM-backed, so a reboot clears them; removing them
  earlier is your call.

### 19.9 Deployment record — 23 October 2026, 01:00–01:04 IST

You authorised this deployment and asked for the Blinkit change rate in the
pre-flight. It followed §19.6. `.env` and `config.json` were never read.

**Pre-flight (01:00).**
- All 20 files to be replaced matched `main`, including `usque-rs`
  (`1ee312fc…`).
- Game mode was off, `filter_aaaa` was 0 and no include existed.
- A lock was present at 01:00:00. It belonged to the cron check that started
  that second, which passed at 01:00:02; the lock was gone 18 s later.
- WARP was PID 20421. `/overlay` was 11 % used, `/tmp` 0 %, and the load 0.41.
- **Blinkit:** F13 has logged no "records changed" line since it was deployed
  (22 October 00:42), and no routes were removed. The records last changed on
  21 October at 05:36. Changes are rare, so by §19.7's rule immediate removal
  stays and no retention change is needed.

**Staging (01:01).**
- 26 files went into `.stage-oi`, plus the running binary as
  `usque-rs.previous`.
- BusyBox `sh -n` passed for every staged script, and all 26 hashes matched
  the Mac.
- The new binary's `--help` listed both new options.

**Promotion (01:01:27–01:01:28),** under an ownerless lock, in this order: the
two helpers, 21 scripts, the two docs, `install_firewall_hook.sh`, `sync`.
- The 01:01:30 check was the first on the new code. It logged "Platform check
  passed." and "Health check passed.".
- `firewall.router_script` is registered with `reload '1'`.
- WARP kept PID 20421, and every `tun0` drop, NAT and FORWARD rule was in place.

**New binary (01:02:12–01:02:16):** `stop_tunnel.sh`, then the swap, then
`tunnel.sh`.
- CONNECT-IP was ready after 2 s, so WARP was down for about 4 s.
- WARP is PID 22623 on `0d1496d3…`, started with `--syslog`. `logread`
  shows "Config loaded", "[connecting] 162.159.198.1:443" and "[connected]
  MASQUE tunnel established".
- Both `tun0` defaults are back, and the Cloudflare trace reports `warp=on` for
  IPv4 and IPv6. Every check since passed.
- **F18 confirmed live.** `/tmp` holds 14 temporary PEM files: key-sized
  (241 bytes) and certificate-sized (~497 bytes) pairs, one pair per earlier
  client start, dated 8 to 22 October. The new client left none.

**Hook test (01:03:06):** `/etc/init.d/firewall reload`.
- fw3 ran the include last, after GL.iNet's four (`firewall.nat6`,
  `firewall.ethernet_ttl`, `firewall.dns_order`, `gl_block.sh`).
- The hook's check started at 01:03:09 ("the firewall was rebuilt") and passed
  at 01:03:10.
- Every rule survived the reload, as firewall3's source says, the game-session
  jump stayed first, and WARP kept its PID.
- Pre-existing and unrelated to this deploy: fw3's configuration warnings, and
  GL.iNet's `firewall.ethernet_ttl` include failing for lack of an
  `ETHERNET_TTL` target.

**Wrap-up.**
- All 34 deploy-set files other than `.env` and `config.json` match the
  branch.
- `.stage-oi` still holds `usque-rs.previous` for a quick binary rollback.
- The branch is merged into `main`.

**Not done:** the loaded-latency measurement (§19.7), which needs your
go-ahead.

**Rollback:** §19.6.

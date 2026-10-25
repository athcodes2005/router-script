# What Claude actually changed, and why — in plain language

Written 25 October 2026. This is a reading companion to
`audit/2026-10-20-full-review/REPORT.md`. That report is written for an
engineer who already knows the system; this one is written for the person who
owns the router and wants to know what was done to it.

Every claim here traces to a commit and a report section. Nothing in this file
changes the system.

---

## 1. The shape of what happened

You asked for: *go through the codebase, find performance improvements,
improve the overall system and infrastructure, and make quality-of-life
improvements.*

That is too vague to act on directly, so it was turned into a process:

1. **Audit everything, read-only.** Every script, the Rust client, the wiki,
   all prior audits. No router access, nothing changed. Result: a numbered
   list of **45 findings, F01–F45**, each with a severity, a confidence level
   ("Confirmed" = reproduced or traced; "Likely" = mechanism proven, trigger
   not observed), the exact file and line, and a proposed fix.
2. **Plus 10 architecture items, A1–A10** — cross-cutting cleanups that are not
   bugs, e.g. "39 constants are copy-pasted across scripts" or "there is no
   way to test a whole pipeline".
3. **Fix them in batches**, one commit per finding, and **every fix starts with
   a test that fails without it**. Nothing was "improved" on vibes.
4. **Deploy through a written checklist** — hash every file, stage it, verify
   on the router, promote under a lock, with a written stop rule and rollback.
   Then write a deployment record with what was actually observed.
5. **Measure.** Several fixes are hypotheses (especially the performance ones).
   Those got a measurement plan and a decision rule *before* being deployed —
   and one of them was measured, showed no gain, and was deliberately left off.

### Timeline

| When | What |
|---|---|
| 20 Oct, 21:16–21:19 | Batches 1–3 deployed: 11 findings (F01–F09, F11, F15) |
| 21 Oct | Batch 4 approved and built: F12–F30 |
| 22 Oct, 00:42–00:47 | Batch 4 deployed |
| 22 Oct, 07:25–07:28 | F12 fix deployed (a leak found *by the post-deploy check*) |
| 22 Oct | F31 found by the validation pass, fixed and deployed |
| 22 Oct | F32–F34 (tunnel start path) fixed and deployed |
| 23 Oct, 01:00–01:04 | "Open issues" batch: the Rust client (F16–F18, F27, F35–F37), F38–F42, A1, A2, A9. **New WARP binary deployed.** |
| 23 Oct, 02:03–02:14 | Loaded-latency measurement. Answer: backpressure does not help → left off |
| 25 Oct | Two more measurement attempts. Uplink was quiet both times → nothing deployed |
| 25 Oct | The 91-minute clock skew noticed during those runs → audited (F43–F45), not fixed |

**Where it stands now:** 42 of 45 findings fixed and live on the router.
F43–F45 are diagnosed but not changed. Two fixes are fully built and tested
but **not deployed** because they need a congested uplink to prove themselves.

---

## 2. Jargon decoder

Read this once; the rest of the file assumes it.

| Term | What it means here |
|---|---|
| **Watchdog** | `ensure_network.sh`, run by cron every 30 s. It checks everything and repairs what broke. It is the reason the router recovers from problems without you. |
| **Captive portal** | IITB's login page that gates internet. Your session expires; a script has to log back in with your token. |
| **WARP / `tun0`** | Cloudflare's VPN. `tun0` is the virtual network card WARP creates. "Public default via `tun0`" = normal internet traffic goes into the VPN. |
| **MASQUE / QUIC** | The modern protocol WARP speaks. `usque-rs` is your Rust client that implements it. QUIC = the transport (think "TCP's faster cousin"); MASQUE = how it carries IP packets. |
| **`eth0`** | The physical Ethernet port to the campus wall socket. Campus traffic must stay here, not go into the VPN. |
| **Default route / metric** | "Where do packets go if no rule matches." When several defaults exist, the **lowest metric wins**. WARP's is 5, the campus's is 10 — so WARP wins *as long as nothing changes that number*. |
| **`/32` and `/22`** | A precise route for one address (`/32`) or a block (`/22`). Used for "these specific sites must bypass the VPN". |
| **dnsmasq** | The DNS server on the router. It caches answers. **SIGHUP** = "reload your config", which also **throws away the cache**. |
| **ipset** | A fast lookup list of IP ranges, used so the firewall can say "all Google traffic" without thousands of rules. |
| **fw3 / firewall reload / restart** | OpenWrt's firewall manager. `reload` keeps custom rules; `restart`/`flush` **deletes every rule anyone added**. |
| **conntrack** | The kernel's table of established connections. If you change routing, existing connections keep their old path until they end. |
| **odhcpd / RA / ULA / NAT66** | The daemon that tells LAN devices their IPv6 address and default gateway (`RA` = router advertisement). `ULA` = a private IPv6 range for your LAN. `NAT66` = translating that out through the tunnel. |
| **MSS clamping** | Forcing TCP to use smaller packets so they fit through the tunnel (MTU 1280) instead of being fragmented and corrupted. |
| **bufferbloat** | Latency caused by a **queue**: packets wait their turn and the queue is too long. This is the whole game-latency saga. |
| **fq_codel / CoDel** | Linux's queue-management algorithms that keep queues short and fair, instead of "first in, first out, wait forever" (a **FIFO**). |
| **BBR2 / CUBIC** | Congestion-control algorithms — how the sender decides its pace. BBR2 paces smoothly; CUBIC reacts to loss. |
| **`set -e`** | Shell option: "abort the script the moment any command fails". Good for safety, dangerous when a failure is optional. |
| **SIGHUP / SIGTERM / SIGPIPE** | Signals. `HUP` = "your terminal went away" (SSH drop). `TERM` = "please stop". `PIPE` = "you wrote to a closed pipe" — this one **kills a shell script instantly, before its cleanup runs**. |
| **PEM** | The file format holding the WARP private key and certificate. |
| **NTP / sysfixtime** | Time sync. OpenWrt has no battery clock, so at boot `sysfixtime` guesses the time from the **newest file in `/etc`**, then `ntpd` corrects it over the network. |
| **ownerless lock** | The maintenance lock is a directory. If it holds an owner file, the code knows who owns it. If it's empty ("ownerless"), it can only be judged by age. |
| **staging / promote** | Copy files to a private directory, verify them, *then* move them into place — instead of overwriting live files one by one. |

---

## 3. The changes, by what they did for you

Ordered by what you'd actually notice, not by ID.

### 3.1 Security: secrets that were leaking

| ID | What was wrong | What changed |
|---|---|---|
| **F01** High | **Both Wi-Fi passwords were written into every diagnostic snapshot**, in plain text, on the router *and* copied to your Mac at file mode 0644 (world-readable). Every 6 hours, on every failure, on every emergency download. Confirmed in a real snapshot from 1 August. | The `ubus` output is filtered for `key`, `password`, `psk`, `sae_password`, `auth_secret`, and similar, replaced with `<redacted>`; snapshots are written `0600` (owner-only). |
| **F05** Medium | The IITB **access token was on `curl`'s command line**, where any process on the router can read it from `/proc/<pid>/cmdline` for up to 30 s per login attempt — including non-root daemons like dnsmasq. | Credentials are fed to curl **on stdin** instead, never as arguments. The produced auth header is tested against a local server so the login still works. |
| **F18** Low | The new client wrote its **private key to `/tmp`** and left it there after every stop (14 stray key/certificate PEM files — 7 pairs, dated 8–22 October). | The key and certificate files are **deleted the moment the crypto library has loaded them**. New client leaves none. |
| **F31** Low | **Anything arriving from the WARP side could open new connections to the router itself** — SSH, the admin UI, DNS. The VPN was, in effect, a way in. | New inbound connections arriving on `tun0` are dropped. Established return traffic is unaffected. |

**What you gain:** the three ways your credentials left the box are closed, and
the router is no longer reachable from inside the VPN.

### 3.2 The watchdog can no longer get stuck, thrash, or lie

This was the biggest cluster: the self-healing script could fail in ways that
made things worse. All of these are about *control flow*, not features.

| ID | What was wrong | What changed |
|---|---|---|
| **F02** High | A persistent Wi-Fi or DNS-config problem **blocked everything else**. The script `exit 1`'d before reaching the portal login and the tunnel. So: a renamed Wi-Fi radio + an expired portal session = **no internet, forever**, with a disruptive `wifi reload` (both radios bounce) every 30 s. | Wi-Fi failure now **continues** instead of exiting (WAN, portal and WARP don't need Wi-Fi); DNS *config* drift continues; only DNS *runtime* being actually down exits. Repairs are rate-limited by per-stage cooldowns. Google's check moved out of the fatal DNS gate. |
| **F04** Medium | A **missing campus route was "repaired" by bouncing the WAN interface** — releasing the DHCP lease, getting a new IP, killing every existing connection and the VPN session — when the fix was one `ip route replace`. Logs show it happening three times in a row, getting `.184`, `.185`, `.186`. | Re-add the route in place first; only cycle the WAN if that fails. |
| **F06** Medium | On a persistent failure it took a **full diagnostic snapshot every 30 s** (21 snapshots in 38 minutes). Retention keeps only 24, so the *start* of the incident — the evidence you actually need — was deleted by the storm itself. | One snapshot per reason per 15 minutes. The onset evidence survives. |
| **F08** Medium | **The game-session routing policy was torn down and rebuilt every 30 s** (12 `iptables` + 5 `ip` calls). During those gaps a new game connection could be routed wrongly for its whole life. | Compare the live rules to the expected set; rebuild **only on drift**. Measured: 13 policy changes per tick → **0**. |
| **F03** High | The 4 firewall rules that let LAN traffic in and out of the tunnel were **never re-checked**. Any firewall restart deleted them, and every health check still said "passed" because the probes run *from the router*, not from a LAN client. Result: all VPN-routed traffic rejected, silently, with no auto-recovery. | The existing NAT/MSS repair now also verifies and reinstalls those rules, same pattern as everything else. |
| **F07** Medium | Health only checked that a `tun0` default route **existed**, not that it **wins**. If anything lowered the campus route's metric, traffic silently bypassed the VPN while health stayed green. | Ask the kernel "which route would `1.1.1.1` actually take?" and warn (log only) if it isn't `tun0`. |
| **F19 / F42** Low | Dropping the SSH connection while `game_mode.sh` or `rotate_tunnel_ip.sh` ran left a **stale lock and half-applied state**. F42 found the deeper cause: a child dying of the hangup makes the shell write to a dead terminal → **SIGPIPE kills the script before cleanup can run**. | `trap ... HUP` and `trap ... PIPE` in both, plus making the restore's logging non-fatal. Reproduced and fixed under dash *and* BusyBox. |
| **F39** Low | The lock could be **stolen from a live process by age** (so a slow WARP restart lost its lock), and an ownerless lock dated in the future (post-reboot clock) was **never** taken over — every tick silently skipped. | One `lock.sh` helper that records PID + process start time + uptime + script name. Live owner is never evicted by age; dead/wrong-PID is taken instantly; 600 s of uptime counts as hung. |
| **F38** Low | `fw3 restart`, `fw3 flush`, `/etc/init.d/firewall stop` **delete every rule router-script adds** — and they stayed gone until the next 30 s tick. Worse: the health check that follows a reboot or a WAN DHCP event rebuilds fw3. | A **firewall hook**: registered as an fw3 include, so it runs *after* fw3 rebuilds and starts a health check 2 s later that reinstalls everything. |
| **F41** Low | Game mode toggled `filter_aaaa` and reloaded dnsmasq each time — but **dnsmasq 2.85 ignores that option**, so it did nothing except flush the cache. | Removed. Game mode's IPv6 REJECT is what actually hides IPv6. |

**What you gain:** the failure modes that needed a human at 3 a.m. are gone or
bounded. This is the single biggest reliability improvement in the batch.

### 3.3 Routing and tunnel correctness

| ID | What was wrong | What changed |
|---|---|---|
| **F09** Medium | **`rotate_tunnel_ip.sh` (get a fresh WARP IP) could never succeed.** Its success test hit Google over IPv6 — which the router blocks — and its IPv4 test went direct, so it never proved the new identity worked. It registered a new device, failed, and rolled back. Every single time. | Success is now Cloudflare's own trace endpoint queried **through `tun0`**, requiring `warp=on`. |
| **F12** Low | Blinkit's direct-WARP-bypass `/32` routes were **added and never removed**, so every address Blinkit ever returned stayed a permanent VPN bypass — including CDN IPs shared with other sites. 20 leaked routes found live. | Keep current + previous generation; delete older ones. |
| **F20** Low | Two separate refreshers wrote `/32` routes and each could **delete a route the other still needed**. | A route is deleted only when no refresher's state file still lists it. |
| **F22** Low | The DNS check didn't verify **upstream order** or reject an accidental **whole-zone forward** (which would break public `iitb.ac.in` hosts). | Both enforced; `configure_dns.sh` already rewrites the whole list, so the existing repair fixes it. |
| **F15** Low | The diagnostic WARP-IPv6 probe targeted Google, which is blocked, so it **always failed** and the code path was dead. | Points at Cloudflare's IPv6 trace. Dead code removed. |
| **F29** Nit | LAN prefix and WAN metric were **hard-coded** in two scripts. | Derived from config; same values today, so no behaviour change. |
| **F30** Nit | `odhcpd` was restarted **twice** per WARP restart. | Once. |
| **F32** Low | Every tunnel start **deleted all campus/public `/32` routes before re-resolving them** — so live traffic briefly moved into the VPN, and a failed lookup lost the route entirely. | Add first, remove only what's no longer listed. |
| **F33** Low | The WAN gateway was taken from "the first non-`tun0` default on **any** interface". | Taken from the WAN interface specifically. |
| **F34** Low | Under `set -e`, **one failed optional host route aborted the entire tunnel start**. | Optional routes now warn instead of aborting. |
| **F44** Low **open** | The LAN→`tun0` ACCEPT rule is inserted at position 1, which puts it **above** the "block Google IPv6" rule — so LAN IPv6 traffic to Google has been going through the VPN since the first restart after 23 September. | Not fixed. Impact is small (LAN clients have no global IPv6, so they prefer IPv4). Two candidate fixes, awaiting your call. |

### 3.4 Deployment: from "hope it worked" to "provably worked"

| ID | What was wrong | What changed |
|---|---|---|
| **F40** Low | `sync_to_router.sh` **overwrote live files one by one** and trusted the transfer. A dropped SSH connection could leave half the deploy applied; a corrupted transfer installed silently. Its lock had no owner, so the watchdog could steal it. | Stage into a private dir → **SHA-256 manifest** → `promote_staged.sh` runs on the router as **one process**, verifies everything, promotes nothing on any mismatch, ignores HUP/PIPE so a dropped SSH can't stop it halfway. |
| **F23** Low | No `sync` after promotion — a power loss seconds later could leave **zero-length `.env` or `config.json`**, and `config.json` failing means WARP never registers again. Local and router `config.json` drifting was also undetected. | Promotion ends with `sync`; a differing local `config.json` is refused unless `--force`. |
| **F25** Low | The README's rollback instructions say `cp usque-rs-upstream-v0.1.0 usque-rs` — **but that file was never shipped to the router**. The documented rollback would have failed at the worst moment. | The rollback binary is now part of the deploy set (+6 MB per sync) and present on the router. |

**What you gain:** you can now deploy in the middle of the day and know it
either fully happened or fully didn't — and the documented rollback actually
works.

### 3.5 The Rust WARP client (`usque-rs`)

You allowed changes to the client, which was previously treated as a black box.
One new binary was built and deployed (23 Oct, `0d1496d3…`, verified
byte-identical across two clean builds).

| ID | What was wrong | What changed |
|---|---|---|
| **F35** Low | **`tun0` write errors were ignored** (`.ok()`). If the network card vanished, the client swallowed every downstream packet while the session still looked healthy. | Count failures; 32 in a row ends the session so a reconnect can fix it. |
| **F16** Low | **No dead-peer detection.** If packets stopped coming back, only the 30–60 s shell watchdog noticed. A closed CONNECT stream was ignored entirely. | 90 s idle timeout (3 keepalives) ends the session as an error; a finished stream ends it cleanly; a reset carries its error code. |
| **F17** Low | A clean close **reconnected with zero delay** — a server that accepts then drops would cause a reconnect storm. | Backoff depends on session length: ≥10 s counts as stable (immediate reconnect), a failure restarts at 1 s and doubles to 30 s. |
| **F37** Low | The client's output went nowhere. **There was no record of why any session ended.** | `--syslog` sends connection events to the system log: connecting, connected, why each session ended, the reconnect delay, fatal errors. **`logread -e usque-rs` is now the first thing to check.** |
| **F36** Low | The MTU and packet-pipeline tests **tested copies of the production code**, not the production code. They could pass while the real thing was broken. | They now unit-test the real functions, and a deliberate mutation (removing the TTL decrement) makes them fail. |
| **F27** Nit | Dead `pending_pkt` variable and its replay block. | Removed. |
| **F10** Medium | The **big one**: `enable_dgram(true, 1000, 1000)` means up to 1,000 packets (~1.3 MB) can queue *inside the client* with no timestamps and no management. That queue is invisible to the kernel's smart queue, so during an upload **every flow — including your game — waits behind it**. Estimated up to ~260 ms at 40 Mbit/s up. | See §4: two attempts, one measured and rejected, one built and unproven. |

### 3.6 Observability: you can now find out what happened

| ID | What was wrong | What changed |
|---|---|---|
| **F06** | diagnostics storm destroyed its own evidence | one snapshot per reason per 15 min |
| **F13** | every Blinkit address change SIGHUPs dnsmasq, **flushing the whole DNS cache**; the rate was unknown so no decision was possible | one log line per change, with how many dnsmasq PIDs were actually signalled |
| **F14** | the 19 Sept audit removed the "slow tunnel" rule to stop false restarts — since then **nothing noticed a tunnel answering in 1.5–4 s** | record each probe's duration; 3 consecutive >1.5 s → WARNING + one snapshot, **never restarts** |
| **F28** | log messages that said the opposite of what happened ("Confirming before restart" logged *after* a restart) | messages now say what actually happened |
| **F37** | client sessions ended with no stated reason | `logread -e usque-rs` |
| **F21 / F43 / F45** | clock skew silently breaks locks and TLS | see §5 — partially fixed, root cause found today |

**What you gain:** the next time something breaks, the log will tell you which
layer failed and why, in sentences instead of guesses.

### 3.7 Speed, CPU and flash wear

| ID | Before | After |
|---|---|---|
| **F11** | the Google DNS-list check ran `printf \| tr \| grep` **once per domain**: **165 process spawns per 30 s tick**, 36 % of everything the watchdog did | one `awk` pass, **~5 spawns** |
| **F08** | 13 policy changes per tick, 17 fork/exec | **0** |
| **F27** | ~10 processes per tunnel stop for legacy-file cleanup, plus a GNU-only `\s` that BusyBox `grep` doesn't understand | 2, and BusyBox-correct |
| **F30** | odhcpd restarted twice per WARP restart | once |
| **A1** | **39 settings copy-pasted 125 times** across the scripts — every one a place to drift | `defaults.sh`, sourced after `.env`; tests fail if a default ever appears twice |
| **overall** | 442 processes per healthy tick (measured, same harness) | **~290 (−34 %)** |

Flash wear matters more than it sounds: the overlay is small, and `F02`'s
reload loop plus `F13`'s cache flushes were both writing to it every tick.

### 3.8 Testability and docs — the quality-of-life work for future-you

- **A8 / `tests/sandbox.py`** — a fake router: scripts run against stub commands
  and a fake `/etc`, so **whole pipelines** can be tested ("DNS broken + portal
  down → did the login still run?"). This is how F02, F04, F08 and F09 were
  reproduced without touching the router.
- **Shell tests: 21 → 137** (89 before the final batch). Every fix came with a
  test that failed first.
  Suites run twice — macOS `sh` and `dash` (closest relative of the router's
  BusyBox `ash`) — plus 20 lock tests and the hangup cases on **real BusyBox
  1.33.1** in a container.
- **Rust: 94 unit + 4 integration tests**, plus mutation checks. `cargo fmt`
  and `clippy -D warnings` clean on every lint group.
- **F24** — a new wiki page (`systems/policy-routing.md`) documenting rule
  order and who owns which mark bits, including the overlap with GL.iNet's own
  bits. Nothing changed in code; this exists so a future change doesn't collide.
  The broader A10 "mark-bit allocation" item is still listed as open.
- **F26** — documentation drift fixed: the docs said 5 campus names, the code
  has 7; the wiki claimed an IPv6 probe was a health requirement when it
  wasn't; a bug page described removed behaviour as active.
- **`c681727`** — `operations/health-recovery.md` split by topic; the wiki now
  has `systems/policy-routing.md`, `systems/host-routes.md`, and a bug page per
  incident.
- **A9** — a platform check once per boot: required tools present, radio
  sections exist, WAN metric is not beating WARP's 5, fw3 include registered.
  Logs "Platform check passed." or one WARNING naming every problem. Changes
  nothing.

### 3.9 The measuring stick it built for itself

`measure_load_latency.sh` (`823d8c7`): saturates the uplink, then the
downlink, and measures round-trip through the tunnel in each phase, labelling
each run with the client options in force. It exists because otherwise "is the
latency better?" is an opinion. Its own bug was found and fixed the same day
(it asked for a 10 GB download, the speed test refuses ≥100 MB, so the
download phase measured nothing and logged 0.0 Mbit/s).

---

## 4. The one performance question that is still open (F10)

Plain version: **when you upload something, your game lags.** Here is what was
learned, because it is the most interesting result in the whole effort.

1. First hypothesis: packets pile up *inside the router's kernel queue*. Fix:
   **backpressure** — stop reading from the network card while the client's
   send queue is deep, so the kernel's smart queue (`fq_codel`) absorbs and
   isolates the burst. Built and shipped (off by default).
2. Measurement (23 Oct, 6 runs): on a quiet uplink it made latency **worse**
   (39–58 ms vs 35 ms) and cost 4–8 % throughput. Counters showed
   `tun0` dropped 51 packets at its own ring while `fq_codel` never held a
   queue at all — so the kernel's smart queue **never engages**; backpressure
   just moved a FIFO from one place to another.
3. Therefore the queue must be **inside the client itself** (quiche's
   1,000-datagram FIFO) — hypothesis F10 all along.
4. Second fix: **CoDel** — drop a datagram that has waited longer than a
   target (20 ms), in the pattern that keeps queues short without crushing
   throughput. Built, 18 new tests, byte-identical double build, **off by
   default, not deployed**.
5. It needs a **congested** uplink to prove itself, and CoDel has never had
   one. The 25 Oct checks (14:14, 14:26) measured 57–73 Mbit/s up, and 23 Oct's
   later runs were 75–80 Mbit/s. The only congested measurements — 23 Oct,
   10–18 Mbit/s up with 122–149 ms medians — tested **backpressure**, not CoDel.
   The pre-agreed rule said stop rather than deploy unproven.

**Net position:** the diagnosis is solid, the fix is written and tested, and
the decision is waiting on a busy hour. Nothing about your internet got worse
in the meantime — the option is off.

---

## 5. Today's discovery: the clock (F43–F45, not fixed)

Found by accident: during the 25 Oct measurement the router's clock read 12:42
while the Mac read 14:14 — **91 minutes behind**, six hours after boot.

- **Why it was wrong at boot (expected):** no battery clock. OpenWrt guesses
  the time from the newest file in `/etc`, which can be arbitrarily old.
- **Why it never fixed itself (the real bug, F43):** `ntpd`'s only server is
  `time1.google.com`. Once WARP is up, DNS hands back Google's **IPv6**
  address (IPv6 ranks higher once a route exists). `google_wan_policy.sh`
  **blocks all of the router's own IPv6 to Google** — so every NTP send fails
  locally, and BusyBox `ntpd` retries the same dead address forever, silently
  (`-n` logs to stderr, which isn't captured).
- **Why it usually works anyway:** it's a race. `ntpd` starts during boot,
  before WARP. If the campus answers its first IPv4 queries, it syncs in
  seconds and keeps that IPv4 address. If the portal session or DNS isn't
  ready yet, it re-resolves the name later — and gets IPv6 — and then never
  syncs again until restart.
- **Why it matters beyond timestamps:** logs are 91 minutes early. If the clock
  is *months* behind (it was 86 days once, after a long power-off), **every
  HTTPS check fails** — expired-looking certificates — so the portal login and
  the probes break, and only NTP can fix the clock, and F43 can stop NTP.
- **Proposed fix (one script, awaiting approval):** narrow the IPv6 block so
  NTP over UDP port 123 is exempt for the router's own traffic. Then `ntpd`
  works over either IP family.
- **F45:** the existing clock warning is silent in exactly this case — it only
  fires when the clock is older than the *scripts*, and today the scripts were
  older than the clock.

---

## 6. Full index of findings

Status as of 25 October 2026. "Deployed" = live on the router.

| ID | Sev | One-line plain meaning | Status |
|---|---|---|---|
| F01 | High | Wi-Fi passwords in every diagnostic dump | Deployed |
| F02 | High | Wi-Fi/DNS failure blocked all other recovery, forever | Deployed |
| F03 | High | Tunnel's firewall accept rules were never repaired | Deployed |
| **F04** | Med | Campus route "repaired" by bouncing the WAN | Deployed |
| F05 | Med | Portal token readable in `ps` | Deployed |
| F06 | Med | Diagnostics storm deleted its own evidence | Deployed |
| F07 | Med | Health checked a route existed, not that it won | Deployed (log only) |
| F08 | Med | Game policy rebuilt every 30 s, with gaps | Deployed |
| F09 | Med | WARP IP rotation could never succeed | Deployed |
| F10 | Med | Client's internal queue causes upload lag | Backpressure measured → off; CoDel built, **not deployed** |
| F11 | Low | Google check cost 165 process spawns/tick | Deployed (~5) |
| F12 | Low | Blinkit VPN-bypass routes never removed | Deployed (after live leak) |
| F13 | Low | DNS cache flushed on every Blinkit change, rate unknown | Deployed (log only) |
| F14 | Low | Slow-but-alive tunnel went unnoticed | Deployed (log only) |
| F15 | Low | WARP IPv6 diagnostic always failed | Deployed |
| F16 | Low | Client never noticed a dead path | Deployed (90 s timeout) |
| F17 | Low | Clean close reconnected with no delay | Deployed |
| F18 | Low | Private key left in `/tmp` | Deployed |
| F19 | Low | SSH drop left stale lock + half-applied state | Deployed |
| F20 | Low | Refreshers deleted each other's routes | Deployed |
| F21 | Low | Clock skew breaks locks/TLS, silently | Deployed (log only) |
| F22 | Low | DNS order + whole-zone forward unchecked | Deployed |
| F23 | Low | No `sync` after deploy; no config drift check | Deployed |
| F24 | Nit | Game mark bits overlap GL.iNet's | Documented only |
| F25 | Low | Documented rollback binary was never shipped | Deployed |
| F26 | Nit | Documentation drift | Deployed |
| F27 | Nit | Legacy cleanup forked; GNU-only syntax; dead code | Deployed |
| F28 | Nit | Log messages said the opposite of the truth | Deployed |
| F29 | Nit | Hard-coded LAN prefix and WAN metric | Deployed |
| F30 | Nit | odhcpd restarted twice per restart | Deployed |
| F31 | Low | Router reachable from inside the VPN | Deployed |
| F32 | Low | Tunnel start deleted routes before re-adding | Deployed |
| F33 | Low | WAN gateway from any interface | Deployed |
| F34 | Low | One optional route failure aborted the start | Deployed |
| F35 | Low | TUN write errors swallowed | Deployed |
| F36 | Low | Tests tested copies, not production code | Deployed |
| F37 | Low | No record of why a session ended | Deployed (`--syslog`) |
| F38 | Low | Firewall restart deleted every rule | Deployed (fw3 hook) |
| F39 | Low | Lock stolen from live owner / never taken when stale | Deployed |
| F40 | Low | Deploy could half-apply | Deployed (staged + manifest) |
| F41 | Low | Game mode toggled a setting dnsmasq ignores | Deployed |
| F42 | Low | SIGPIPE skipped cleanup on SSH drop | Deployed |
| F43 | Med | `ntpd` latches onto a blocked IPv6 address → clock never syncs | **Open, proposed** |
| F44 | Low | LAN Google IPv6 bypasses its own block rule | **Open, proposed** |
| F45 | Low | Clock warning silent for most skews | **Open, proposed** |

Also delivered, not numbered as findings: `defaults.sh` (A1), the boot-time
platform check (A9), `tests/sandbox.py` (A8), `measure_load_latency.sh`,
`lock.sh`, `firewall_hook.sh`, `install_firewall_hook.sh`,
`promote_staged.sh`, the policy-routing wiki page (F24), and the wiki
reorganisation.

---

## 7. What is left, and what only you can decide

| Item | State | Needs |
|---|---|---|
| F43 clock fix | One-script change, designed | Your go-ahead |
| F43 confirmation | Read-only 2-minute SSH script, 13 checks | Your go-ahead to connect |
| F44 LAN Google IPv6 | Two candidate fixes | A rule-order check first |
| F10 upload CoDel | Built, tested, off by default | A measurement at a busy hour |
| `measure_load_latency.sh` download fix | On branch, one file | A deploy |
| Merge the three branches into `main` | `main` != router until then | After the above settle |
| Existing diagnostic snapshots on Mac/router | Still contain Wi-Fi passwords from before F01 | **Your call** — delete/redact them, and consider changing the Wi-Fi passphrase if any were shared |

That last one is the only item with a security deadline attached, and it is
the one thing no script can fix for you.

---

## 8. How to check any of this yourself

```sh
cd /Users/atharva/projects/router-script

git log --oneline 2ba81fe..HEAD        # every change, in order
git show <commit>                      # one finding, exactly
grep -n '^### F' audit/2026-10-20-full-review/REPORT.md   # the reasoning
grep -n '^## ' audit/2026-10-20-full-review/REPORT.md     # report structure
tail -n 200 wiki-llm/wiki/log.md       # chronological history
```

On the router, the two commands worth knowing:

```sh
logread -e usque-rs      # why the VPN connected / disconnected
tail -n 40 logs/ensure.log   # what the watchdog did and why
```

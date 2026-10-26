# Validation audit — 2026-10-26

Scope: router-script @ `0225890` (main = deploy = origin) and usque-rs-openwrt @ `6368b73`.
Read-only. No SSH, no deploy, `.env`/`config.json` not read. Orchestrated by Opus; area audits by
Sonnet agents (A runtime, B deploy/CI, C Rust crate, D wikis); medium+ findings re-verified by Opus.

## Baseline

- router-script: 169/169 unittest pass; shellcheck clean of real bugs; `dash -n` clean.
- usque-rs-openwrt: `cargo test --locked` 101 unit + 4 integration pass (macOS; Linux-only
  sendmmsg path reviewed by reading); `cargo clippy --all-targets -D warnings` clean.
- Local `usque-rs` sha256 `77eb75c4…` = extracted GitHub v0.2.1 aarch64-musl asset; archive sha
  `7e8e54a2…` = `.usque_release_sha`. All CLI flags passed by `tunnel.sh` exist with matching semantics.
- MTU 1320 / MSS 1280/1260 / DNS 127.0.0.1#5453 consistent across code, tests and wiki.
- Nothing secret tracked in git (both repos). `gh` not installed: CI status checked via public API only.

## Prioritised findings (verified = re-checked by Opus)

| ID | Sev | Verified | Summary |
|----|-----|----------|---------|
| B1 | medium | yes | Cron `update_from_git.sh` → `fetch_usque_rs.sh` with `USQUE_RELEASE_TAG=latest`: any new usque-rs release auto-deploys to the live router within 15 min, no human gate |
| B2/B7 | medium | yes | A release/commit that fails the health check is rolled back but not recorded; retried (tunnel restart) every 15 min forever |
| C1 | medium | yes | usque-rs `release.yml` not gated on CI (v0.2.1 tagged on a red-CI commit); combined with B1 a broken tag reaches the router |
| C10 | medium | yes | Public fork tracks disassembly + strings dump of proprietary Cloudflare `warp-svc`, plus local absolute paths / campus & GL-MT3000 topology. Already pushed: removal from history needs a rewrite + force-push (owner decision) |
| D6 | low | yes | Private LAN IP in public fork `wiki-llm/raw/sources/upstream-setup-notes.md:11` |
| B3 | low-med | yes | `usque-rs-upstream-v0.1.0` holds v0.2.0 on the router but real v0.1.0 on the Mac; `sync_to_router.sh` overwrites the router's rollback slot with v0.1.0 |
| B4 | medium | — | `update_from_git.sh` and `sync_to_router.sh` maintain separate file lists; only sync list is tested |
| B5 | plausible | — | `sync_to_router.sh` doesn't write `.deployed_commit`; cron updater may overwrite a manual sync if `GITHUB_REPO` is set |
| A1 | medium | — | wiki `systems/dns.md:14` says dnsproxy "parallel upstream mode"; generated YAML has no `upstream-mode` |
| A2 | low-med | yes | `configure_dns.sh` (`set -eu`) aborts on failed `dnsproxy restart` before dnsmasq/pin/ipset repair |
| A4 | low | — | No dnsproxy liveness check/restart; `dns_runtime_ok` passes whenever dnsmasq is up |
| A5 | low | yes | `game_mode.sh:115,143` re-execs `"$0" status` → 127 when invoked as `sh game_mode.sh on` |
| D1 | medium | yes | 18 Sources paths in router wiki point at removed `usque-rs-optimized/`, `audit/`, `PROJECT_CONTEXT.md` |
| D2/D3 | low-med | — | README omits usque-rs split / `fetch_usque_rs.sh`; index blurb for warp-client stale |
| D4 | low | yes | router `log.md` out of order (09-19 after 09-22), stray mid-file sections |
| C11 | low | — | usque wiki claims clippy `--all-features` and a `release` branch; neither true |
| C2–C6, C12 | low | — | release matrix race, dead packaging step, unpinned Go/toolchain, unchecked MSRV, dispatch can tag wrong ref; sendmmsg non-EAGAIN error drops whole batch |
| A3, A6–A11, A13, A14, B6, B13, D5, D7, D11–D13 | low/info | — | see appendices |

Withdrawn: **A12** (wiki already documents the 600 s hung-owner takeover).

Not inspected: `wiki-llm/raw/assets/hostel-01-network-config-2026-08-01.png` (may show network details).

## Suggested fix batches (pending approval)

1. **Gate binary auto-deploy (B1, B2, C1):** default `USQUE_RELEASE_TAG` to a pinned tag (or `AUTO_FETCH_USQUE=0`), record failed archive/commit shas and skip them; add `needs: test` + tag/Cargo version check to `release.yml`.
2. **Rollback slot naming (B3):** rename to a version-neutral `usque-rs.prev` (touches fetch/sync/update/tests/wiki).
3. **DNS robustness (A1, A2, A4):** fix wiki or set `upstream-mode`; don't abort on restart failure; add dnsproxy liveness repair.
4. **Small script fixes (A5, A6, A7, B4 test).**
5. **Wiki repairs (D1–D4, C11, A10 wording).**
6. **Public-fork hygiene (C10, D6, D7):** remove from tree going forward; history rewrite only if owner chooses.

Any change to router behaviour still needs a separate deploy go-ahead. Note B1 means pushing a usque-rs tag is itself a deploy.

---

## Appendix A-runtime (agent report)

### Audit A: router runtime scripts (read-only)

Scope: ensure_network, tunnel, stop_tunnel, defaults, configure_dns, dns_flow, configure_lan_ipv6, google_wan_policy, game_mode, firewall_hook, lock, login, rotate_tunnel_ip, refresh_blinkit_dns, rotate_logs, diagnose, measure_load_latency, paths, configure_wifi, monitor_game_network. Compared against wiki-llm/wiki. No router access; nothing was run except shellcheck and grep.

Overall: no high-severity defects. The code is consistent on MTU/MSS/DNS port (see "Verified OK"). Findings are mostly low severity, plus one wiki claim that the code does not back up.

## Findings

### A1 (medium) wiki vs code: "parallel upstream mode" is not configured
- Wiki: `wiki-llm/wiki/systems/dns.md:14-19` (and `log.md` ~line 1004) says dnsproxy runs "in parallel upstream mode ... returning whichever encrypted resolver answers fastest (~20 ms)".
- Code: `configure_dns.sh:55-70` writes a YAML with `upstream`, `bootstrap`, `listen-addrs`, `listen-ports`, `timeout` only. There is no `upstream-mode: parallel` (or `fastest_addr`). The dnsproxy default is load_balance.
- Scenario: `ensure_network.sh` calls `configure_dns.sh` on any drift, and the script overwrites `/etc/dnsproxy/dnsproxy.yaml` unconditionally. If parallel mode was set by hand on the router, or comes from GL.iNet's init script flags, the next drift repair or firmware change can silently revert it. If it was never set, the ~20 ms latency claim describes a different mode.
- Fix: add `upstream-mode: parallel` to the heredoc if that is intended, and have `dns_config_ok` grep for it. Otherwise correct the wiki. PLAUSIBLE for the router-side part: I could not read `/etc/init.d/dnsproxy` on the router.

### A2 (low-medium) `configure_dns.sh:72` unguarded dnsproxy restart under `set -e`
- `/etc/init.d/dnsproxy restart` has no `|| true`, and the script runs `set -eu`.
- Scenario: the restart returns non-zero (binary missing after a firmware upgrade wipes /etc, or the config is rejected). The script aborts before the dnsmasq server list, campus forwards, portal/SSO pins and Google ipsets are written. DNS drift then repeats every `STAGE_REPAIR_COOLDOWN` (300 s) and the UCI state is never repaired.
- Fix: `/etc/init.d/dnsproxy restart || log "dnsproxy restart failed"`. dnsmasq falls through to 8.8.8.8 anyway.

### A3 (low-medium) `configure_dns.sh:66-68` writes GL.iNet's `gl-dns-v2` settings, undocumented
- The script sets `gl-dns-v2.@dns[0].mode='secure'` and `proto='doh'`, then commits.
- Neither the wiki (grep finds no mention of `gl-dns`) nor the tests cover it.
- Scenario (PLAUSIBLE, unverified): GL.iNet's own DNS service reads these keys and regenerates its dnsproxy/dnsmasq config. That would fight the strict-order list on a later `gl-dns` reload.
- Fix: document the reason in the wiki, or drop the lines if dnsproxy is started only through the YAML.

### A4 (low) dnsproxy is never liveness-checked or restarted
- `dns_runtime_ok` (`ensure_network.sh:171-174`) resolves `internet.iitb.ac.in`, which is a local `address=` pin (`configure_dns.sh:130-131`). It always returns 10.x as long as dnsmasq is alive.
- `dns_config_ok` (`ensure_network.sh:151-153`) only greps the YAML for `tls://1.1.1.1:853` and the bare string `5453`.
- The only dnsproxy process check is `check_platform_once` (`:563`), which runs once per boot and only logs.
- Scenario: dnsproxy crashes. Every query hits the dead `127.0.0.1#5453` first (fast ICMP refusal), then falls back to 8.8.8.8 in plaintext. Nothing restarts it and nothing logs it until the next reboot. This undermines the "encrypted DNS primary" claim in the wiki.
- Fix: in `dns_config_ok` or a separate step, add `pidof dnsproxy` and restart `/etc/init.d/dnsproxy`, rate-limited.

### A5 (low) `game_mode.sh:94, 113` re-exec via `"$0"`
- `"$0" status` is run after `on` and `off`. `$0` is not a path, so under `sh game_mode.sh on` (relative name, no `./`) the shell searches `$PATH` and gets 127. This also requires the +x bit.
- Under `set -e` the script exits 127 after applying the changes. The marker is written and the lock is released by the EXIT trap, so the state is correct but the exit code is wrong.
- Cron and the tests use `./game_mode.sh`, so this is unexercised.
- Fix: replace with `sh "$DIR/game_mode.sh" status`.

### A6 (low) `.env` is not sourced, or is sourced too late, in several scripts
- `rotate_tunnel_ip.sh:14-15` and `rotate_logs.sh:10-11` never source `.env`. `.env` overrides of `TUN_IF`, `WAN_IF`, `MAX_DIAGNOSTICS` and similar are ignored. Example: rotation's `warp_trace_ok --interface $TUN_IF` would use the default.
- Every script sources `paths.sh` before `.env` (tunnel, stop, configure_dns, login, ensure_network, ...). `LOG_DIR`, `DIAGNOSTICS_DIR` and `PERSISTENT_STORAGE_FALLBACK_PERCENT` set in `.env` are therefore ignored, because `LOG_FILE` is computed first.
- Fix: source `.env` before `paths.sh`, or document the variables as environment-only.

### A7 (low) `rotate_logs.sh:52-59` omits the `latency` log
- `measure_load_latency.sh:18` writes `latency.log`, but it is not rotated and has no cap. It is manual-use only, so the growth is slow.
- Fix: add `rotate_file "$(prepare_log_file latency)"`.

### A8 (low) hard-coded values that duplicate defaults
- `game_mode.sh:78` uses the literal `10.200.1.11` instead of `$CAMPUS_DNS_IP`.
- `dns_flow.sh:52-55` uses the literal `192.168.8.1`.
- `configure_lan_ipv6.sh:93, 99` use `br-lan` instead of `$LAN_IF`.
- `google_wan_policy.sh:9-12` hard-codes table 102, priorities 690/710 and the mark 0x100000. The wiki documents them, but they are not in `defaults.sh`.
- No functional effect today. These drift if `.env` changes the values.

### A9 (low) stale MSS rules after a TUN_*_MSS change
- `stop_tunnel.sh:134-138` and `tunnel.sh:182-184` remove only the current MSS value and the legacy 1240/1220 ones. `ensure_network.sh:479, 482` delete only 1240/1220.
- Scenario: `.env` changes `TUN_IPV4_MSS` from 1280 to, say, 1300. The new rule is inserted at the top and the old `--set-mss 1280` rule stays. TCPMSS only lowers the value and continues, so the old, lower value keeps winning until `fw3 restart` or reboot.
- Not an issue for the shipped defaults.
- Fix: delete any `-i tun0 ... TCPMSS --set-mss N` rule whose N differs from the configured one, by listing with `-S`.

### A10 (low) game-session routes are never expired when sessions end
- `ensure_network.sh:436-449`: when `FOUND=0` (no live game conntrack entry) the old routes and `GAME_SESSION_ROUTES_FILE` are kept indefinitely. Removal happens only when a later scan finds at least one new address.
- Wiki `systems/host-routes.md` ("Stale routes are removed only after every configured name produced IPv4 answers") is not accurate for this refresher: it removes stale routes whenever FOUND=1 and never when 0.
- Impact: harmless /32 direct routes persist until `stop_tunnel.sh`.
- `TMP_ROUTES` (`:411`) also lacks an EXIT/trap cleanup. A SIGTERM mid-scan leaks one small file in /tmp.

### A11 (low) unbounded delete loops lack a `|| break` guard
- `tunnel.sh:122`, `stop_tunnel.sh` (all `while ... -C ...; do ... -D ...; done` loops) and `ensure_network.sh:388-390`.
- `tunnel.sh:176-178` and `:191-193` do have the guard. The others do not.
- Failure scenario (PLAUSIBLE, not observed): `-C` succeeds and `-D` keeps failing, which only happens if the iptables binary or the xtables lock misbehaves between the two calls. The loop would then spin while holding the maintenance lock.
- The `ip rule del` loops terminate naturally (they stop at the first failure).
- Fix: add `|| break` to every `-D` inside a `-C` loop.

### A12 (low, wiki) `operations/health-recovery.md:5-10`
- It says a live owner "is never displaced by age" and, a few words later, that one holding the lock for 600 s is taken over as hung.
- `lock.sh:84-91` implements the 600 s takeover (`MAINTENANCE_LOCK_MAX_HOLD`), so the first sentence is wrong.

### A13 (low, observability) `diagnose.sh` omits MSS and mangle state
- It captures `iptables -L FORWARD` and the nat table, but not `iptables/ip6tables -t mangle -S` (TCPMSS clamps, `GAME_SESSION_POLICY`, Google marks), not `ipset list -n`, and not the INPUT chain with the tun0 NEW drop.
- The MTU/MSS rollout is the most recent change, so snapshots cannot show the clamps. `ip addr show dev tun0` does show the MTU.
- Fix: add `run iptables -t mangle -S` / `ip6tables -t mangle -S`.

### A14 (info) Blinkit hosts are written to the flash overlay
- `BLINKIT_HOSTS_DIR` defaults to `/etc/router-script/blinkit-hosts`, so every change of the record set is a flash write.
- Writes happen only on change, so this is bounded. CDN address churn is unmeasured. Noting it for flash-wear awareness only.

## Shellcheck triage
Command: `shellcheck -s sh` (and again with `-x`) on all 20 scoped files. No warnings or errors remain after excluding these:
- SC1090 / SC1091 (non-constant source) are expected.
- SC2012 (`ls` in `rotate_logs.sh:62, 65`) is style; filenames are generated and safe.
- SC2329 on `tunnel.sh:35` is a false positive: `cleanup_on_exit` is called via `trap`.
- SC2086 on `login.sh:85, 122` (`$RESOLVE_OPTS`) is deliberate word-splitting of two `--resolve` options and is correct.
- No bashisms found: the `==` and `[[` hits are inside awk. There is no `local`, no `[[ ]]`, no `source`, no arrays, no `read -p`, no `${var//}`. `date -r`, `stat -c` and `[ -nt ]` are all supported by BusyBox 1.33.

## Verified OK
- MTU/MSS consistent across `defaults.sh` (1320 / 1280 / 1260), `tunnel.sh` (`--mtu`, `ip link set mtu`, `--clamp-mss-to-pmtu` on `-o tun0`, `--set-mss` on `-i tun0`), `ensure_network.sh` `nat_rules_ok` and `ensure_nat_and_mss_rules`, `stop_tunnel.sh`, tests, and the wiki (`architecture`, `warp-client`, `traffic-routing`, `opencode-pqc`).
- Clamp arithmetic: 1320-40 = 1280 and 1320-60 = 1260 match the `--clamp-mss-to-pmtu` result; `--set-mss` only lowers.
- Legacy MSS values 1240/1220 are cleaned up in `tunnel.sh`, `stop_tunnel.sh` and `ensure_network.sh`.
- `DNS_SERVERS` (`127.0.0.1#5453 8.8.8.8 8.8.4.4 $CAMPUS_DNS_IP`) agrees across `defaults.sh`, `configure_dns.sh`, the `dns_config_ok` awk order check, the wiki and the tests. The dnsproxy YAML listens on port 5453.
- Every dnscrypt reference in the scoped scripts is a comment, and the commented `DNSCRYPT_TOML` is not read by any live code path. No live path uses it.
- Every variable in `defaults.sh` is used somewhere; there is no unset use of a variable under `set -u` that I could find. Locally defaulted variables (`LAN_IP6ASSIGN`, `WIFI_APPLY`, `PORTAL_ETYPE`, the retry-file paths, `GOOGLE_STATE_DIR`) are all defaulted before use.
- `lock.sh`: atomic mkdir, a serialized takeover directory, PID-reuse detection via /proc stat field 20 (equal to field 22 after stripping pid and comm), uptime-based hold limit, and a safe release after takeover. `game_mode.sh`, `rotate_tunnel_ip.sh` and `measure_load_latency.sh` set HUP/PIPE/INT/TERM traps that release the lock.
- Cron cadence (`*/1` plus `sleep 30`) and the fw3 hook match the wiki. CLOCK_CHECK_INTERVAL=600 and the 120 s skew threshold match. The date-to-epoch awk arithmetic is correct.
- Game-session chain: the `-C`-then-rebuild logic, the first-rule check (`sed -n '2p'` after the `-P` line), and the mark mask 0xf0000 versus Google's 0x100000 (bit 20) do not collide. The Google IPv6 reject ordering check (four rejects before the LAN-to-tun0 ACCEPT) is correct.
- `google_service_ranges.txt` has no duplicate prefixes (a duplicate would make `ipset add` abort under `set -e`), and no CR characters in the list files.
- `login.sh`: credentials go to curl via stdin config rather than argv, queries are redacted from logs, and `set -e` is correctly suspended inside `if recover_stale_session`.
- `diagnose.sh` redacts Wi-Fi secrets in the `ubus` status output and does not print `.env`. `refresh_blinkit_dns.sh` stages outside the addn-hosts directory and replaces the file atomically.
- Bad-route cleanup in `refresh_host_routes` and `route_listed_elsewhere` correctly avoids deleting a /32 that another refresher lists. A partial DNS failure preserves old routes.

## Appendix B-deploy (agent report)

### Audit B - deployment/update tooling, CI, repo hygiene (read-only)

Limits: `gh` is not installed here; unauthenticated GitHub API returned total_count 0 for router-script Actions runs (private repo or no runs) so CI status is UNVERIFIED. The unittest suite was not completed (backgrounded run exceeded timeout). shellcheck (same flags as CI) and dash -n pass locally with zero findings.

## Findings

B1 MEDIUM fetch_usque_rs.sh:27-32, defaults.sh:59 (+ update_from_git.sh:33-35, cron */15)
 Unpinned: USQUE_RELEASE_TAG defaults to "latest". Any new GitHub release is auto-installed on the production router within 15 min with no human gate. The sha256 is fetched from the same release (integrity only, not authenticity; no signature).
 Scenario: a bad/compromised release (or one that passes `nativetun --help` but misbehaves under load) restarts the tunnel on the only internet link unattended.
 Fix: set USQUE_RELEASE_TAG=v0.2.1 default (bump deliberately), or pin expected sha in repo.

B2 MEDIUM fetch_usque_rs.sh:175-192 (rollback path)
 After a failed health check the script rolls back but never records the failed sha, and .usque_release_sha still != release sha. The next cron tick (15 min) re-downloads, stops the tunnel, installs the same bad binary, fails, rolls back again: a recurring ~tens-of-seconds outage every 15 minutes, indefinitely.
 Fix: write a ".usque_bad_sha" and skip that sha; log loudly.

B3 LOW-MEDIUM fetch_usque_rs.sh:151-155,183 / naming
 `usque-rs-upstream-v0.1.0` is now a generic "previous binary" slot: on the router it holds v0.2.0 (83deac89..) while the name says v0.1.0 and "upstream". The Mac's local copy of that file is the genuine old binary (sha e27256fe.., dated 30 Jul), and sync_to_router.sh ships the local file (FILES list, line 104), overwriting the router's v0.2.0 rollback slot with e27256fe (v0.1.0, lacks MTU/pacing flags). Also the Mac-side --download-only (lines 119-122) only backs up if the file does not exist, so the Mac slot is never refreshed. Confusing and mildly dangerous: an operator following README "rollback = copy usque-rs-upstream-v0.1.0" gets v0.1.0 on one machine and v0.2.0 on the other. Also the docs/log call v0.2.0 "backed up as ...v0.1.0".
 Fix: rename to usque-rs.previous (keep alias for one release), do not ship it from the Mac (it is router-generated state), update tests/wiki.

B4 MEDIUM update_from_git.sh:142 vs sync_to_router.sh:104 (+ cron)
 Two hand-maintained file lists; tests only check sync's list (test_sync.py:117), not DEPLOY_FILES parity. Currently equal modulo config.json/.env/blocked_sites.txt (intentional). Also deployed files deleted from git are never removed from the router.
 Fix: add parity unit test, or derive from one shared list.

B5 MEDIUM (PLAUSIBLE) sync_to_router.sh vs update_from_git.sh interplay
 sync_to_router.sh deploys the working tree (possibly uncommitted) but does not write .deployed_commit. If router .env has GITHUB_REPO set, the next cron tick (:07/:22/:37/:52) sees TARGET_SHA != empty CURRENT_SHA and, if CI green, overwrites the manually synced files with the deploy branch. Memory says router != main since 2026-10-25 17:56, so a hot-fix sync could be silently reverted. Conversely, sync pushes the local .env, so it controls whether the updater is enabled at all (local .env is 70 bytes, probably no GITHUB_REPO => script updater inert; only the binary fetch runs, since fetch happens before the `[ -n "$GITHUB_REPO" ] || exit 0` check at line 38). I did not read .env, so UNVERIFIED which is the case. Wiki implies the git CD is "the" updater; in practice it may be only the binary auto-fetch.
 Fix: sync_to_router.sh should record `.deployed_commit` (or a "manual" marker that pauses the updater); document the live state.

B6 LOW update_from_git.sh:87-117
 CI gate: requires >=1 check-run and all concluded success/neutral/skipped. Any third-party check-run counts; no check that the commit is a descendant of the currently deployed one (force-push of deploy to an older green commit downgrades prod); no signature check; GitHub token compromise or repo write access = root code execution on the router every 15 min. `sh -n` is the only validation (a syntax-valid but broken script is only caught by the ensure_network health gate).
 Fix: require descendant relationship (compare API), consider a protected deploy branch.

B7 LOW update_from_git.sh:183-202 rollback
 Rollback restores only files that existed in backup; files new in the update stay. Rollback is not recorded, so after rollback .deployed_commit is unchanged and the same bad commit is retried every 15 min (same flapping as B2: promote stops the tunnel, restarts, health check, rollback). Fix: record failed TARGET_SHA and skip it.

B8 LOW fetch_usque_rs.sh:68-74,89-92,111
 Failure behavior: sha fetch failure => exit 0 (silent, logged only on router); archive download failure => exit 1 (caller ignores via `|| true`); mismatch => exit 1, nothing installed (verified by test_corrupt_archive_sha_is_rejected). Variable named GITHUB_Download_Base (mixed case, cosmetic). tar -xzf extracts without checking members (trusted source, low). If no previous binary exists (first install) there is no rollback target (line 183), so a bad first binary stays in place.

B9 LOW .gitignore / repo hygiene
 .gitignore covers .env, config.json(.previous), logs/*, diagnostics/, usque-rs, usque-rs-upstream-v0.1.0, .usque_release_sha, .deployed_commit. `git ls-files` contains no .env/config.json/diagnostics; only logs/.gitkeep. `git log --all -- .env config.json` is empty (never committed). Residual: wiki-llm/raw/sources/audit/** tracks `before/*.sh` copies, deploy.py and a PNG (hostel-01-network-config-2026-08-01.png) - PLAUSIBLE topology/Wi-Fi info leak; check the PNG and wiki-llm/wiki/security/secrets-and-trust.md (matched a grep for 'secret' only by name). Tracked source copies in raw/ are also globbed by nothing (CI uses *.sh at root only) - fine.

B10 INFO CI (.github/workflows/ci.yml)
 Runs on push+PR for all branches: sh -n + dash -n, shellcheck -s sh -S warning, `python3 -m unittest discover -s tests -v` (full suite, 20 test files). Nothing stale found. Gaps: actions/checkout@v4 unpinned by sha; no python-version pin; tools/*.py not linted; CI green status UNVERIFIED (no gh). Since update_from_git requires a check-run, if Actions is disabled/failing no deploy happens (fail-safe).

B11 INFO main vs deploy
 main == deploy == origin/main == origin/deploy == 0225890 ("wiki: record usque-rs v0.2.1 rollout..."). `git log main..deploy` and `deploy..main` empty; no diff. So the git-CD target equals current main; but see B5: the router itself can differ from main (manual sync, memory F48).

B12 LOW wiki vs code (operations/deployment.md, systems/warp-client.md)
 - deployment.md "Git CD updater" omits that fetch_usque_rs.sh runs first and independently of GITHUB_REPO, and that .deployed_commit is not written by sync.
 - deployment.md says rollback binary is `usque-rs-upstream-v0.1.0`/"rollback binary" - see B3 naming.
 - warp-client.md says fetch "backs up the previous binary ... promotes under lock.sh" - accurate. It says "USQUE_RELEASE_TAG=latest" (accurate, but see B1).
 - deployment.md: "scripts ... receive mode 0755": code does chmod 755 ./*.sh - accurate (configure_wifi.sh is 0644 locally; fixed on router, but CI/other tooling that executes it directly locally would fail; cosmetic). monitor_game_network.sh also 0644.
 - Cron: "twice-per-minute health check, 15-minute updater, six-hour rotation and diagnostic" matches install_cron_pipeline.sh.
 - deployment.md claims the Mac "trap ... restarts a previously running tunnel" - matches cleanup().

B13 LOW sync_from_router.sh:54-58 / collect_diagnostics
 Pulls logs and diagnostics (hold Wi-Fi keys per memory) to the Mac; gitignored so ok, but no chmod 600/umask on pulled files (diagnostics are created 077 on router, scp preserves only without -p -> default umask on Mac => world-readable 644 locally). Fix: `umask 077` in sync_from_router.sh and download_emergency_diagnostics.sh.

B14 LOW sync_to_router.sh:52,55
 `chmod 600 .env config.json` ok. fetch --download-only only runs when usque-rs missing, so the Mac binary is never upgraded by sync; the router's own cron fetch handles it, and a Mac sync with an OLDER local usque-rs (e.g. before this rollout) would downgrade the router binary (and .usque_release_sha is not shipped, so the router then re-fetches within 15 min = another restart). Local currently matches v0.2.1 so no issue today.

## Verified OK
- No secrets tracked; .env mode 0600, config.json mode 0600; .env.example has placeholders only.
- usque-rs and usque-rs-upstream-v0.1.0 are NOT tracked (gitignored, 5.8 MB each); intended per .gitignore comment. Both are ELF aarch64 static stripped.
- .usque_release_sha = 7e8e54a2d2f3...2a0 == GitHub v0.2.1 asset usque-rs-aarch64-linux-musl.tar.gz digest (also == -v0.2.1.tar.gz). `releases/latest` = v0.2.1. Downloaded the asset: sha matches; extracted usque-rs sha = 77eb75c495f0...98b44 == local `usque-rs`. Documented values correct.
- fetch_usque_rs.sh: checksum compared before extraction; atomic mv from .new; lock; pre-lock `nativetun --help` smoke test; backup then rollback on health failure; mismatch leaves existing binary intact (tested).
- sync_to_router.sh: uses scp -O, staging dir 0700, SHA-256 manifest, promote_staged.sh verifies manifest before touching anything, takes maintenance lock via lock.sh, helpers promoted first, sync after, HUP/PIPE ignored; blocklist and config.json divergence guarded (hash only). Every script referenced by ensure_network/tunnel/stop_tunnel/firewall_hook (collect_diagnostics, configure_dns, configure_wifi, defaults, firewall_hook, google_wan_policy, lock, login, paths, refresh_blinkit_dns, rotate_logs, ...) is in FILES; all *.sh and data files except Mac-only sync scripts are shipped.
- sync_from_router.sh and download_emergency_diagnostics.sh use scp -O; the latter validates the remote path.
- bootstrap/cron/firewall hook scripts idempotent (marker-block crontab, uci delete then set).
- update_from_git.sh: token via stdin (-K -), syntax-check all scripts, staged+manifest promote under lock, health gate, rollback, `.deployed_commit` only on success.
- shellcheck and dash -n clean; CI config covers sh -n, dash, shellcheck, full unittest discover.
- main == deploy (no divergence).

NOTE (update): the full unittest suite did complete locally: 169 tests OK in 159 s.

## Appendix C-rust (agent report)

### Audit C - usque-rs-openwrt (Rust crate), read-only, 2026-10-26

Scope: <local path> at main 6368b73; tag v0.2.1 = 756ec94.

## What was built/tested
- Mac (aarch64-apple-darwin, cargo/rustc 1.99.1, own CARGO_TARGET_DIR): `cargo test --locked` = 101 unit + 4 integration tests PASS; `cargo clippy --all-targets --locked -- -D warnings` clean. Builds fine on macOS (libc/rtnetlink are linux-gated).
- NOT verifiable on Mac: the `#[cfg(target_os="linux")]` sendmmsg path (send_batch_mmsg and the Linux branch of UdpSendBatch::flush) is compiled out, so neither clippy nor the udp_send_batch test exercises it here. tests/tunnel_mtu.rs "passes" on Mac only because it skips without root/TUN. No musl cross build attempted (no Docker). `gh` is not installed; used unauthenticated GitHub REST via curl instead.
- CI/release state (REST API): CI on main HEAD 6368b73 = success. CI on tag commit 756ec94 = FAILURE, yet Release for 756ec94 = success (see C1). Release v0.2.1 has all 6 targets, each with versioned + stable archive and .sha256. Stable aarch64 sha256 = 7e8e54a2...e2a0, matches wiki.

## Findings

### C1 - MEDIUM - .github/workflows/release.yml:1-20, 49-75
Release is not gated on CI/tests. A tag push builds and publishes immediately. Evidence: v0.2.1 (756ec94) was published while CI for that very SHA was red. Scenario: a tag on a commit with failing tests/clippy ships an aarch64 binary that router-script's fetch_usque_rs.sh (tracks `latest`, AUTO_FETCH_USQUE=1 default) auto-installs on the router. Fix: add a `needs:` test job (or workflow_call to ci.yml) and a check that tag == Cargo.toml version.

### C2 - LOW/MEDIUM - release.yml (matrix upload step) 
Each of 6 parallel matrix jobs calls softprops/action-gh-release for the same tag, with generate_release_notes only on aarch64. Known create-race; and `releases/latest` flips to the new tag as soon as the first (any-target) job creates it, before aarch64 assets exist. router-script handles that gracefully (404 on .sha256 -> WARNING, exit 0), so impact is a delayed update, not a bad install. Fix: split a final `release` job with `needs: build` that downloads artifacts and publishes once (and lists aarch64 last / only after all pass).

### C3 - LOW - release.yml:~98-102
Dead code: builds bare `usque-rs-aarch64-linux-musl` + .sha256 but they are not in the upload `files:` list. Remove or upload.

### C4 - LOW (supply chain) - Cross.toml pre-build
`curl -sSfL https://go.dev/dl/go1.22.10...tar.gz | tar -xzf -` as root with no checksum; `apt-get` unpinned. Also floating `dtolnay/rust-toolchain@stable`, `taiki-e/install-action tool: cross` (unpinned cross), actions by tag not SHA. Release binaries are therefore not reproducible. Fix: verify sha256 of the Go tarball, pin cross version and toolchain (rust-toolchain.toml), pin action SHAs.

### C5 - LOW - Cargo.toml / clippy.toml
clippy.toml says `msrv = "1.75"` but Cargo.toml has no `rust-version`, and CI only tests `stable` (1.99). MSRV claim is unverified. Fix: set rust-version or drop msrv.

### C6 - LOW - src/tunnel.rs:455-468 (flush, Linux branch) - PLAUSIBLE impact
Any sendmmsg error other than WouldBlock (ENOBUFS, EMSGSIZE, ECONNREFUSED pending from an ICMP unreachable on the connected UDP socket) does `log::warn!` and `return`s, discarding all `total` already-dequeued packets (no per-packet retry), whereas a partial-success sendmmsg retries the remainder individually. For QUIC this is just loss (and ECONNREFUSED would then also surface from the next socket.recv()/try_recv() with `?` and end the session via main loop lines ~1130 and ~1218; pre-existing behaviour). Also sendmmsg errors on the 1st message only; after a partial send the error that stopped it is silently re-tried by the per-packet loop (fine). Suggested fix: on non-WouldBlock error fall through to the per-packet loop (which logs per packet and breaks) or at least treat ENOBUFS like WouldBlock. log::warn per flush could be noisy if RUST_LOG=warn under sustained ENOBUFS.

### C7 - INFO - src/tunnel.rs:365-400 unsafe review (no bug found)
mem::zeroed on iovec/mmsghdr is valid (all-zero is valid for libc POD types; msg_name null, namelen 0, which is correct for a connected socket - flush only uses mmsg when all dests == peer, and the socket is connected since the fallback uses socket.send). iov pointers reference `buffers` (immutably, cast_mut but sendmmsg only reads) and stack `iovecs`, both alive across the call. count <= 64 guaranteed by is_full(); indexes in range. `MSG_DONTWAIT as _` is correct for both glibc (c_int) and musl (c_uint) flag types. Return -1 -> last_os_error; partial returns handled (start = sent; rest sent in order). try_io clears writable readiness on EAGAIN and the fallback `send().await` re-arms it - correct. Redundant: MSG_DONTWAIT is unnecessary under try_io but harmless.

### C8 - INFO - pacing coalescing (tunnel.rs:329-336, 1285-1313)
Logic is sound: `now` is sampled once; packets whose `at` is < now+500us are batched (bounded burst of <=~500us worth of pacing at the current rate, max 64 pkts); first later packet is held in paced_buf, loop stops pulling from quiche until it fires. No packet is lost or reordered. Minor PLAUSIBLE throughput quirk: for pacing gaps 0.5-1 ms (10-21 Mbit/s) tokio sleeps round up to ~1 ms ticks, but quiche's `at` then lies in the past so the following packets burst out; average rate preserved. No action needed.

### C9 - INFO - MTU edge cases vs TUN_MTU=1320
dgram prefix is 2 bytes (varint flow id + context 0, see flow_prefix) so a 1320-byte IP packet needs a 1322-byte DATAGRAM payload; quiche max-writable depends on the peer's CID length and pn length. If it is smaller, dgram_send_vec returns BufferTooShort -> handled in queue_tun_packet (counted dropped + ICMP PTB via effective_datagram_ip_mtu, floored at 1280). IPv4 PTB only if icmp::compose_icmp_too_large supports it (not exhaustively re-verified). discover_pmtu(false) rationale (quiche 0.22 client bug) is documented and consistent with code. tun_buf = mtu+128 is adequate. With `--no-iproute2` the binary does not set the TUN MTU (router-script sets it with `ip link set ... mtu`, tunnel.sh:200) - consistent.

### C10 - MEDIUM (public-fork hygiene) - wiki-llm/raw/sources/audit/2026-10-25-warp-official-vs-usque/**
Committed to a public repo: (a) local absolute paths `<local path>` in evidence/cc-variant-decoder-disasm.txt:2 and quicsettings-default-disasm.txt:2, and `<local path>` in wiki/log.md:29, overview.md:18, build-and-release.md:25 (leaks username/local layout); (b) disassembly and a gzipped strings dump of Cloudflare's proprietary `warp-svc` binary (evidence/warp-svc-strings.txt.gz, *-disasm.txt, deb-inventory/digests) - redistribution/copyright and ToS risk for a public fork; (c) REPORT.md:255 and wiki quic-and-pacing.md:8 mention "campus" network; src/tunnel.rs:1203 comment "campus/WAN"; (d) wiki bugs/warp-official-audit-2026-10-25.md:23 and release.yml:35 name the exact router model (GL-MT3000); (e) upstream-setup-notes.md:11 has 192.168.1.1 (OpenWrt default, benign). No credentials, private keys, tokens, MACs, or real public IPs found (git grep). Fix: remove warp-svc-derived evidence from the public history/tree (or keep only the prose report), scrub /Users paths, genericize "campus".

### C11 - LOW - wiki claims that contradict code/CI
- wiki/operations/build-and-release.md says CI runs `cargo clippy --all-targets --all-features -- -D warnings`; ci.yml has no `--all-features` (removed in 54f0182).
- wiki/log.md:19 says release workflow publishes on "the `release` branch"; release.yml triggers only on tags v*.*.* and workflow_dispatch (a `release` branch exists but is unused).
- wiki says release artifacts "static"; fine, but also says "reproducible" build (see C4).
- log.md says v0.2.1 includes the 756ec94 fix: tag does point at 756ec94, OK. But tag's .cargo/config.toml still had target-cpu=native for *-gnu targets (harmless for musl; removed later in 3f03161, which is untagged).
- CI-red on the tagged SHA is not mentioned in the wiki.
- Wiki test counts (101 unit + 4 integration) are correct.

### C12 - INFO - release.yml workflow_dispatch
Default input tag `v0.2.0`; dispatch builds the selected ref's code but uploads to the typed tag, so a mismatched ref/tag publishes wrong code under an existing tag (softprops overwrites assets). Fix: check out `ref: ${{ inputs.tag }}`.

## Verified OK
1. Cargo.toml version 0.2.1 == latest tag v0.2.1 == GitHub latest release.
2. Release profile: opt-level 3, lto, codegen-units 1, panic=abort, strip=symbols (mipsel overrides panic=unwind via env; fine).
3. .cargo/config.toml at HEAD has no rustflags; no target-cpu=native.
4. libc = "0.2" declared under `[target.'cfg(target_os = "linux")'.dependencies]` (covers musl); non-Linux build works (verified on Mac).
5. Cargo.lock is committed; tests run with --locked OK.
6. CI: fmt, clippy (-D warnings), test jobs exist and HEAD is green.
7. Release assets/format vs router-script/fetch_usque_rs.sh: asset `usque-rs-aarch64-linux-musl.tar.gz` (defaults.sh USQUE_ASSET_NAME) and `.sha256` exist; sha file format is `<hash>  <name>`, script takes awk field 1 and validates hex; tarball holds `usque-rs` at root (script expects $WORK/extracted/usque-rs); `nativetun --help` self-check works.
8. CLI interface used by router-script/tunnel.sh all exist with correct semantics in src/main.rs: global `--config`; `register --accept-tos`; `nativetun --interface-name --mtu --congestion-control {cubic,bbr,bbr2,reno} --ready-file --syslog --tun-backpressure N --upload-codel MS`. Help-grep capability probes ('congestion-control', 'ready-file', '--syslog', '--tun-backpressure', '--upload-codel') all match clap help output (unit test pins `--upload-codel <MS>`). Defaults: mtu 1280 in binary, router passes 1320 explicitly. WARP_CC default in tunnel.sh is cubic (matches binary default); wiki/benchmarks used bbr2 via env.
9. Process name `usque-rs` (pidof) matches [[bin]] name; TUN name is passed via --interface-name from TUN_IF (tun0); ready file is written after CONNECT-IP ready and removed on disconnect (per CLI doc; mark_ready/clear_ready_file present).
10. Config JSON fields written atomically 0600 via tempfile; config.json and *.tar.gz are git-ignored.
11. Syslog events go to /dev/log via events.rs (router-script uses `logread -e usque-rs`); did not grep any specific log string from router-script that would need to match (router relies on ready-file + pidof + ip link, not log lines).
12. Idle timeout 3 x keepalive(30s)=90s matches wiki; reconnect backoff constants consistent with wiki.
13. No credentials/keys in repo or wiki (other than hygiene items in C10).

## Not checked
Router-side behaviour, musl cross-build locally, Linux execution of sendmmsg path, why CI failed on 756ec94 (run logs not fetched; unauthenticated API gives no logs), icmp.rs IPv4 PTB details in depth.

## Appendix D-wiki (agent report)

### Audit D: wiki-llm structural integrity (read-only)

Scripts: scratchpad/chk.py (index/links/Sources/length), scratchpad/sec.py (secret scan).
Values are masked; only location and kind are reported.

## Findings

D1 | MEDIUM | router-script/wiki-llm/wiki/** (Sources sections) | 18 repo paths cited in Sources do not exist. Two stale families:
 (a) `../../../usque-rs-optimized/...` (src/config.rs, tls.rs, tunnel.rs, packet.rs, Cargo.toml, tests/tunnel_mtu.rs). That dir no longer exists after the split into usque-rs-openwrt. Cited in: security/secrets-and-trust.md:84-86; bugs/outage-hardening-2026-08-01.md:73-74; bugs/warp-cpu-spin-2026-08-07.md:63; bugs/known-issues.md:100; bugs/warp-forwarding-starvation-2026-08-09.md:85,87; bugs/tmp-exhaustion-2026-08-01.md:41; flows/boot-and-recovery.md:57.
 (b) removed top-level `../../../audit/...` (consolidated into wiki-llm/raw/sources/audit/ in 902988b), and `../../../PROJECT_CONTEXT.md`. Cited in: bugs/opencode-pqc-mss-clamping-2026-10-08.md:45; bugs/game-latency-audit-2026-09-19.md:50-51; systems/policy-routing.md:59; systems/google-wan.md:90; bugs/known-issues.md:98.
 Fix: repoint (a) to `<local path>` as a repo/tag reference (or `athcodes2005/usque-rs-openwrt` path); repoint (b) to `../raw/sources/audit/<dir>/...` and `../raw/sources/project-context-2026-10-25.md`.

D2 | MEDIUM | router-script/README.md:1-9 | README does not mention the usque-rs split into athcodes2005/usque-rs-openwrt or fetch_usque_rs.sh (binary delivery, update_from_git AUTO_FETCH_USQUE). It still reads as if the Rust client is local. Fix: add one line about the separate repo and `fetch_usque_rs.sh`.

D3 | LOW | router-script/wiki-llm/wiki/index.md:12 (and systems/warp-client entry) | The index describes warp-client as "Rust MASQUE client modules and lifecycle". It is now a binary-delivery/CLI-contract page, and the source lives in another repo. Fix: reword to "usque-rs binary delivery (fetch_usque_rs.sh), CLI contract with tunnel.sh, v0.2.x".

D4 | LOW | router-script/wiki-llm/wiki/log.md:306-318 and :320 | Chronology violated in two ways. (1) The "## 2026-09-19 Game latency audit" entry (line 320) and the later 09-19/09-23 entries follow 2026-09-22 (line 295). (2) A "## Maintenance protocol" section and a "## Sources" block sit mid-file (306, 313), between history entries. Appended entries then contain per-entry "## Sources" headings, which is inconsistent with the first 21 entries. Fix: do not rewrite history. Going forward, append only, and move the protocol text to a header note.

D5 | LOW | router-script log.md history | Append-only check: of 12 commits touching log.md, only 9554e60 removed lines. It reworded one in-progress bullet ("First attempt" became "Two attempts, 14:14 and 14:26 IST") in the 2026-10-25 CoDel entry (~line 790). It is a minor edit of an existing entry and counts as a rewrite of prior text (the entry was not at the end). No other deletions. The usque-rs-openwrt log.md has no deleted lines (first commit 3f03161 onward; the earlier commits only add).

D6 | LOW | usque-rs-openwrt/wiki-llm/raw/sources/upstream-setup-notes.md:11 | PUBLIC fork: an ssh command `root@192.168.x.x` shows a private LAN IP and the router's /root/usque path. This is the only private IP in the wiki. Fix: sanitize to `<router-ip>`, or note the file is imported-as-is. raw/ is meant to be immutable, so decide deliberately.

D7 | LOW | usque-rs-openwrt/wiki-llm/wiki/overview.md:18; operations/build-and-release.md:23; log.md:29 | PUBLIC fork: the wiki cites the local path `<local path>`. This leaks a local username and environment layout, which the contract forbids. Also names GL-MT3000 and "campus wireless" (systems/quic-and-pacing.md:8, bugs/warp-official-audit-2026-10-25.md:23) and the `athcodes2005` account (the account name is public by nature). Fix: use "the router-script repo" without absolute paths.

D8 | LOW | router-script/wiki-llm/wiki/systems/warp-client.md:6,38+ ; sources.md ; log.md | Absolute `<local path>` paths in the private wiki. Not a secret; noted for consistency only.

D9 | INFO | router-script raw/sources/audit/2026-10-20-full-review/REPORT.md, project-context-2026-10-25.md, raw/sources/audit/2026-09-19/* | Many public IPs (about 105 lines). From the prefixes (8.8, 1.1, 9.9, 103.21, 108.158/159, 99.86, 13.32, 216.239, 162.159) they are public resolvers or CDN/Google/Cloudflare ranges, not a WAN address. The 10.x/172.16/192.168 campus addresses appear in about 195 lines (systems/campus-wan.md, dns.md, architecture.md). That is expected for the private router wiki, but the wiki and raw dirs must never be published. No live WAN IP found.

D10 | INFO | Security scan results | No private keys, JWTs, or WPA/password assignments in either wiki. The 3 "secretassign" hits in router-script raw/.../before/login.sh:117,118,146 are shell variable names (TOKEN_LOGIN_STATE), not values. The 9 hits in usque raw quiche-0.22.0-lib.rs are upstream source. Long base64-like strings are SHA digests and Rust symbols (architecture-symbols.txt, digests.txt, log.md:105 deployed-binary SHA-256). No MAC addresses found in text (hostel-01 PNG not inspected: image may contain Wi-Fi/network details, so check the screenshot manually).

D11 | LOW | Page length (>150 lines) | Only log.md in router-script (1063 lines). Log is exempt by nature; consider yearly archives only if wanted. No page in usque-rs-openwrt exceeds 150. No router page is above 102 lines (known-issues, health-recovery), though several exceed the 80-line preference.

D12 | LOW | usque-rs-openwrt/wiki-llm/wiki/log.md | Only 2 entries, both dated 2026-10-26, covering the whole v0.1.0 to v0.2.1 history, including the C4be176 and v0.2.1 events. There is no dated entry for the version bump to 0.2.0 or the v0.2.1 release as a distinct step. Minor.

D13 | LOW | usque operations/build-and-release.md | Does not state the current version (v0.2.1), the checksum file format consumed by fetch_usque_rs.sh (`sha256sum` output, first field), or the MTU 1320 / `--mtu` default. Mentions only the handoff. The facts exist in log.md and overview.md. Fix: add one line each.

## Cross-wiki consistency (item 7)
Consistent: version v0.2.1 (Cargo.toml 0.2.1, tags v0.1.0/v0.2.0/v0.2.1); asset name `usque-rs-aarch64-linux-musl.tar.gz` + `.sha256` (release.yml lines 101-105, defaults.sh:60, fetch_usque_rs.sh:34-35); checksum mechanism (sha256sum output, first field compared; both wikis agree); MTU 1320 (defaults.sh:14, both wikis); flags `--mtu`, `--congestion-control`, `--ready-file`, `--syslog`, `--upload-codel`, `--tun-backpressure`; benchmarks (133.3 Mbit/s up, upload RTT 19 ms median, 5 ms download) match across both logs. MSS 1280/1260 appears only on the router side (correct ownership). Gap: the usque wiki does not repeat the `mtu 1320` default or that fetch_usque_rs.sh takes `latest`; see D13.
Caveat: the router wiki says "down from 46 ms median on v0.2.0", usque says 46 to 19 ms; consistent.

## Verified OK
- Index completeness: all 40 router pages and 11 usque pages are listed in index.md; no dead index entries (both wikis).
- `[[...]]` links: all resolve, using wiki-root-relative paths without .md (e.g. `[[systems/dns]]`, `[[log]]`). Zero dead links in either wiki.
- Every non-log page ends with a `## Sources` section in both wikis.
- Cited paths in Sources exist apart from D1 items. usque Sources (Cross.toml, ci.yml, release.yml, Cargo.toml, tests) all exist.
- Router README links to wiki-llm index, overview, architecture, deployment, health-recovery, AGENTS.md; all exist.
- warp-client.md accurately describes the split, `fetch_usque_rs.sh`, defaults.sh vars, rollback binary, and update_from_git AUTO_FETCH_USQUE.
- Log append-only: no history deletion beyond D5 in router; none in usque.
- No .env or config.json read.

## Outcome (2026-10-26)

Owner approved batches 1, 3, 4+2, 5 and "remove from tree only" for the public fork.
Implemented by Sonnet agents (one commit per finding, test first), reviewed and integrated by Opus:

- router-script branch `validation-2026-10-26` (not merged, not deployed): B1 (`USQUE_RELEASE_TAG`
  default `v0.2.1`), B2/B7 (`.usque_failed_sha`, `.git_failed_commit`, `--retry-failed`), B3
  (rollback slot `usque-rs.prev`, legacy fallback, no longer shipped), B4 (list-consistency test),
  A1 (wiki), A2, A4 (`dnsproxy_alive_repair`), A5, A6, A7, D1, D2, D3, A10 (wiki). 189 tests pass;
  shellcheck adds only CI-excluded SC1090; `dash -n` clean; 0 dead wiki Sources paths.
- usque-rs-openwrt branch `fix-validation-2026-10-26` (not pushed): C1 (release gated on tests +
  tag/version check), C10/D6/D7 (binary-derived evidence removed from tree, local details
  scrubbed; history unchanged), C11.

New findings during fixing (not fixed): **N1** `rotate_logs.sh` exits 1 on success (EXIT trap's
last `[ ] &&` test); **N2** `ensure_network.sh`, `tunnel.sh`, `game_mode.sh`,
`measure_load_latency.sh` and others source `.env` after `paths.sh`, so `LOG_DIR` overrides there
are ignored. Caveats: A4 restarts a crash-looping dnsproxy every tick without backoff; B2 records a
release as failed even when the health check failed for an unrelated outage (retry with
`--retry-failed`). Router `.env` may override `USQUE_RELEASE_TAG` (unchecked; not read).

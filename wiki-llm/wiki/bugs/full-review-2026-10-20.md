# October 2026 full review and firmware 4.11.0 audit

Between 20 and 26 October 2026, a full read-only audit of all 23 shell scripts,
the Rust WARP client (`usque-rs-optimized`), and the GL.iNet 4.11.0 firmware
upgrade produced 52 numbered findings (F01–F52) and 10 architecture items
(A1–A10). Every implemented fix was committed test-first against the sandbox
(`tests/sandbox.py`).

## Security and credential boundaries

- **F01:** `diagnose.sh` redacts WPA2/SAE secrets (`key`, `password`, `secret`,
  `psk`) from `ubus call network.wireless status`, and `collect_diagnostics.sh`
  writes snapshots at mode `0600` ([[../security/secrets-and-trust]]).
- **F05:** `login.sh` feeds portal credentials to `curl -K -` on stdin so they
  never appear in `/proc/<pid>/cmdline` ([[../operations/portal-login]]).
- **F18:** `usque-rs` deletes its temporary private-key and certificate PEM
  files immediately after `quiche` loads them ([[../systems/warp-client]]).
- **F31:** `tunnel.sh` and `ensure_network.sh` drop unsolicited (`NEW`) inbound
  connections on `tun0` for IPv4 and IPv6.

## Watchdog, locking, and deployment

- **F02, F03, F04, F06, F07, F08:** Wi-Fi, DNS-config, and LAN-IPv6 failures no
  longer block WAN/portal/WARP recovery; stage repairs and failure snapshots use
  cooldowns; missing `LAN↔tun0` FORWARD rules are repaired in place; campus
  routes are re-added before cycling the WAN; game policy is rebuilt only on
  drift ([[../operations/health-recovery]]).
- **F19, F39, F40, F42:** `lock.sh` tracks owner PID, process start time, and
  uptime; `promote_staged.sh` verifies a SHA-256 manifest and ignores
  `HUP`/`PIPE` under the lock ([[../operations/deployment]]).
- **F38:** `firewall_hook.sh` (fw3 include) triggers a health check right after
  `fw3` rebuilds the firewall ([[../flows/boot-and-recovery]]).
- **A1, A8, A9:** Shared defaults live in `defaults.sh`; `tests/sandbox.py`
  runs full-pipeline tests; `check_platform_once` verifies firmware assumptions
  once per boot.

## Rust client, routing, and firmware 4.11.0

- **F09, F12, F13, F15, F20, F22, F32–F34:** WARP rotation validates via
  Cloudflare's trace on `tun0`; Blinkit and host-route refreshers coordinate
  ownership; `tunnel.sh` adds routes without pre-deleting live exceptions
  ([[../systems/host-routes]]).
- **F10, F16, F17, F35–F37:** `usque-rs` logs lifecycle events via `--syslog`,
  times out dead paths at 90 s, aborts after 32 TUN write errors, backs off
  short sessions, and tests production packet functions.
- **F43–F45:** Router-originated IPv6 to Google uses WARP; LAN Google IPv6
  rejects stay above the `LAN→tun0` ACCEPT; clock skew >120 s against probe
  `Date` headers logs a warning ([[../systems/google-wan]]).
- **F46–F52:** `bootstrap_router.sh` registers `/root/router-script/` and
  `/etc/router-script/` in `/etc/sysupgrade.conf`; `ensure_network.sh` repairs
  LAN IPv6 in place after GL.iNet's `99-disable_ipv6` hotplug hook;
  `refresh_blinkit_dns.sh` signals `/var/run/dnsmasq/dnsmasq*.pid`; transfer
  scripts use `scp -O`; `update_from_git.sh` pulls CI-verified commits from the
  `deploy` branch with automatic health-gate rollback.

## Sources

- `../../raw/sources/audit/2026-10-20-full-review/REPORT.md`
- `../../raw/sources/changes-explained-2026-10-25.md`
- `../../raw/sources/audit/2026-10-25-warp-official-vs-usque/REPORT.md` (binary-derived evidence files removed from the public repo on 2026-10-26)
- `../../../ensure_network.sh`, `../../../defaults.sh`, `../../../lock.sh`, `../../../update_from_git.sh`

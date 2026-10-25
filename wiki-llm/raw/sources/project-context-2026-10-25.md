# Router Project Context

Last updated: 2026-09-19

## Purpose

This project configures a GL.iNet GL-MT3000 router running OpenWrt for an IIT Bombay hostel room.

Target behavior:

1. Keep the IITB captive portal session authenticated automatically.
2. Route all public IPv4 and IPv6 traffic through the Cloudflare WARP tunnel on `tun0`.
3. Keep campus-private IPv4 (`10.0.0.0/8`) and WARP transport endpoints directly on `eth0`.
4. Resolve DNS using plain resolvers first (`8.8.8.8`, `8.8.4.4`, `10.200.1.11`), with DoH as last resort.
5. Forward internal-only campus hosts (`internet.iitb.ac.in`, `sso.iitb.ac.in`, `cc.iitb.ac.in`, `moodle.iitb.ac.in`, `portal.iitb.ac.in`, `mulyankan.cse.iitb.ac.in`, and `webmail.iitb.ac.in`) to campus DNS `10.200.1.11`, never the whole `iitb.ac.in` zone.
6. Keep Wi-Fi latency stable with the correct India regulatory domain and
   conservative 20 MHz/80 MHz channel widths.

## Current known-good design

- Router LAN: `192.168.8.1/24` on `br-lan`
- Captive portal login script: `login.sh`
- DNS entrypoint for clients: `dnsmasq` on `192.168.8.1:53`
- DNS upstream chain (strict-order):
  1. `8.8.8.8` (Google primary — fast, plain DNS)
  2. `8.8.4.4` (Google secondary)
  3. `10.200.1.11` (campus resolver)
  4. `127.0.0.1#5453` (dnscrypt-proxy DoH — last resort, CPU heavy)
- Campus DNS forwarding:
  - `internet.iitb.ac.in -> 10.200.1.11` (via dnsmasq server=/domain/ip)
  - `sso.iitb.ac.in -> 10.200.1.11`
  - `moodle.iitb.ac.in -> 10.200.1.11`
  - `portal.iitb.ac.in -> 10.200.1.11`
  - Do not forward the entire `iitb.ac.in` zone. Public hosts like `campus.placements.iitb.ac.in` return NXDOMAIN on campus DNS.
- WARP client: `usque-rs`
- Tunnel interface: `tun0`
- Full-tunnel routing with underlay exceptions:
  - `10.0.0.0/8` stays on `eth0`
  - WARP transport endpoints stay on `eth0`
  - IPv4 and IPv6 defaults go through `tun0`

## Important fixes already made

- `dnscrypt-proxy.toml` must keep `block_ipv6 = false`, otherwise AAAA answers are hidden.
- `dhcp.@dnsmasq[0].filter_aaaa` must stay `0`.
- `dhcp.lan.ra_default` must stay `2`.
  - This is important because the LAN uses ULA + NAT66 through the tunnel.
  - With `ra_default=1`, clients could receive a ULA but miss the IPv6 default route.
- `tunnel.sh` keeps campus `10.0.0.0/8` and WARP endpoints on `eth0`.
- `tunnel.sh` installs MSS clamping and IPv4/IPv6 NAT on `tun0`.
- `ensure_network.sh` must stop the tunnel and recover `wan` first if the WAN DHCP lease disappears.
- Failed WARP restarts fall back to direct IPv4 WAN for a five-minute cooldown
  instead of leaving a dead `tun0` default or restarting every minute.
- Runtime `/tmp` usage at or above 90% triggers diagnostics and direct fallback;
  this prevents RAM-disk exhaustion from turning into a tunnel restart storm.
- `.env` and `config.json` are secret-bearing files and must stay mode `0600`.
- Wi-Fi radios use country `IN`, 2.4 GHz `HE20`, and 5 GHz `HE80`; the health
  pipeline repairs drift from this stability profile.
- WARP registration writes are atomic; registration responses without a peer
  are rejected instead of panicking or writing a partial config.
- QUIC handshake and CONNECT phases are bounded, endpoint key pinning is
  mandatory, and repeated session failures use exponential retry backoff.
- WARP connects immediately and writes a readiness marker only after CONNECT-IP;
  public defaults are never installed merely because the TUN device exists.
- QUIC keepalive sends an ACK-eliciting frame rather than only waking a timer.
- The established QUIC loop floors expired timers at 5 ms. This prevents a
  zero-duration quiche timeout from pinning one CPU core while socket/TUN events
  continue to wake immediately under real traffic.
- IPv4 packet handling validates IHL and checksums the complete options-bearing
  header, preventing malformed or options-bearing traffic from breaking a loop.
- Health checks distinguish Ethernet carrier, DHCP lease, Wi-Fi runtime, DNS
  runtime, core campus routing, optional campus routes, and WARP readiness.
- Portal recovery requires two failed direct probes and performs three bounded
  post-token checks before logout. Tunnel health uses one pre-restart result and
  one post-restart result, avoiding contradictory flapping-probe decisions.
- Deployments stage into a private directory with a SHA-256 manifest.
  `promote_staged.sh` then promotes the set on the router only if every file
  checks out, as the live owner of the maintenance lock, and a dropped SSH
  connection cannot stop it halfway. A failed transfer leaves the installed set
  intact and restores a prior tunnel.
- WARP registration rotation refuses to overwrite prior recovery state and
  restores the previous registration/tunnel if failure or interruption occurs.

### WARP throughput optimization (2026-07-30)

- The previous `usque-rs` binary delivered only about 4.5-10.5 Mbps through
  WARP, below the roughly 20 Mbps average bitrate of a remote Jellyfin stream.
- `usque-rs-optimized/` is based on upstream `v0.1.0` and:
  - reuses a receive buffer instead of allocating for every QUIC datagram;
  - samples QUIC display statistics once per second instead of every packet;
  - exposes `cubic`, `bbr`, `bbr2`, and `reno` through
    `--congestion-control`.
- Earlier short router tests reached roughly 110-146 Mbps with `cubic`, `bbr`,
  and `bbr2`, but a 2026-08-09 long-lived-session test showed CUBIC collapsing
  to about 4-5 Mbps with high CPU. The active `.env` selects `WARP_CC=bbr2`;
  the executable's fallback remains CUBIC for compatibility.
- The established-session loop now bounds every forwarding stage and honors
  quiche `SendInfo::at` pacing deadlines instead of emitting future-scheduled
  packets immediately.
- `usque-rs-upstream-v0.1.0` is retained as the rollback binary.

### Captive portal hung session (2026-03-16)

- The IITB captive portal sometimes authenticates successfully but fails to grant internet.
- `login.sh` checks internet via `eth0` after the first login attempt.
  - If still down, it hits `logout.php`, waits, then does a fresh `login.php`.
- `check_internet` in `login.sh` must use `--interface $WAN_IF` (i.e. `eth0`).

### Merged token/SSO portal (2026-08-01)

- The retired `internet-sso.iitb.ac.in` hostname no longer resolves; token login
  is now initiated at `internet.iitb.ac.in/login.php`.
- IITB's headless access-token flow requires trusted Basic Auth across its HTTPS
  redirects. Removing trusted redirect forwarding causes the request to land on
  the interactive SSO CAPTCHA page even with a valid token.
- `login.sh` uses HTTPS-only trusted redirects and logs only request metadata,
  never the returned HTML/CAPTCHA body. If token login still fails it writes the
  interactive-login marker so `ensure_network.sh` keeps a direct fallback.

### Publicly addressed campus-only pages (2026-08-01)

- Some IITB-only pages, including `www.cc.iitb.ac.in/page/ip_hostel`, use a
  public address but reject non-campus source IPs.
- Campus DNS forwarding returns private answers for selected services, while
  IITB's public `103.21.124.0/22` remains direct for cached public DNS answers.
- `CAMPUS_DIRECT_DOMAINS` is resolved at tunnel startup and health checks verify
  that every current IPv4 answer remains routed through `eth0`.
- This exception policy is router-only. Client devices require no host routes or
  network-service-order changes when they use the router connection.

### Stale lock file (2026-03-16, reworked 2026-10-22)

- Every script that changes routing or firewall state takes one `mkdir` lock,
  `.ensure_network.lock`, through `lock.sh`.
- The owner file records PID, process start time, uptime and script name. A live
  owner is never evicted by age; a dead one, or a PID that now belongs to another
  process, is taken over at once; an owner holding it for 600 s of uptime is
  taken over as hung.
- Only a lock that records no owner (taken by hand) still ages by the clock:
  180 seconds, or at once if it is dated in the future after a clock reset.

### Tunnel teardown on persistent internet failure (2026-03-18)

- When internet stays down after `login.sh`, `ensure_network.sh` stops the tunnel so traffic falls back to `eth0`.

### IPv6 Router Advertisement refresh (2026-03-18)

- When `ensure_network.sh` restarts the tunnel, it also restarts `odhcpd` to push fresh RAs.
  (Since 2026-10-20 this happens once, inside `tunnel.sh`, after the IPv6 default exists.)

### Architecture change: full public dual-stack WARP (2026-07-31)

- **Routing**: Both IPv4 and IPv6 public defaults use `tun0`. Campus-private
  `10.0.0.0/8`, IITB public `103.21.124.0/22`, and WARP transport endpoints
  remain on `eth0`.
- **Campus services**: the access portal, SSO, Moodle, ASC, and Computer Centre
  resolve via campus DNS to `10.0.0.0/8`, while cached public IITB answers still
  follow the direct public-prefix exception.
- **Legacy state**: destination blocklists and per-client WARP policy files are
  retained for rollback but are not used by the full-tunnel launcher.

## Operational flow

- `bootstrap_router.sh`
  - one-shot setup for Wi-Fi, DNS, LAN IPv6, cron pipeline, and tunnel health
- `configure_wifi.sh`
  - enforces the regulatory domain and latency-oriented channel widths
- `login.sh`
  - verifies public IPv4 via `eth0` and logs into the IITB portal if needed
  - handles hung portal sessions by performing logout then fresh login
- `ensure_network.sh`
  - health-check wrapper that repairs DNS drift, LAN IPv6 drift, captive login, and tunnel health
  - stops the tunnel and falls back to `eth0` if internet remains down after login recovery
  - tunnel restarts refresh LAN IPv6 Router Advertisements (`tunnel.sh` restarts `odhcpd` once)
  - owner-aware lock protection prevents overlapping recovery actions
  - bounds every HTTP probe, monitors `/tmp`, and rate-limits failed WARP retries
- `install_cron_pipeline.sh`
  - installs the recurring router cron jobs
- `collect_diagnostics.sh`
  - saves a diagnostic snapshot under `diagnostics/`
  - use `--emergency` flag for emergency prefix
- `download_emergency_diagnostics.sh`
  - from the Mac, generates an emergency report on the router and downloads it locally
- `rotate_logs.sh`
  - keeps long-running logs from growing forever

## Sync workflow

From local to router:

```sh
./sync_to_router.sh
```

From router back to local state:

```sh
./sync_from_router.sh
```

## First commands to run during future debugging

On local:

```sh
cd /Users/atharva/projects/router-script
./sync_from_router.sh
```

On router:

```sh
cd /root/router-script
./diagnose.sh
./dns_flow.sh
tail -n 80 logs/ensure.log
tail -n 80 logs/tunnel.log
crontab -l
```

## Legacy blocklist

`blocked_sites.txt` is retained only for rollback compatibility. It does not
affect the active full-tunnel architecture: all public IPv4 and IPv6 already
use WARP, while campus-private IPv4 stays direct.

## Model-oriented documentation

`wiki-llm/wiki/index.md` is the complete architecture, operations, flow,
incident, security, and source map for future maintainers and LLM sessions.

## 2026-09-19 latency audit

Optional DNS host-route maintenance is now independent of WARP liveness and
preserves prior routes on partial lookup failures. The watchdog confirms
failures of a live tunnel after three seconds and logs the failing layer.
Game-mode toggles use the maintenance lock and retain the WAN fallback gateway.
See `audit/2026-09-19/REPORT.md` for scope, evidence, validation and limitations.

## Blinkit IPv6 bypass gap — 2026-09-19

`refresh_blinkit_dns.sh` supplies refreshed IPv4-only records for api3/jumbo Blinkit and legacy api2.grofers.com
API names. dnsmasq exact local zones suppress their AAAA/HTTPS answers;
other sites retain IPv6. Addresses are resolved upstream and routed via WAN
before publishing. The installed dnsmasq 2.85 ignores `filter_aaaa` UCI options;
do not treat that setting as proof of effective IPv6 filtering.

## Post-Quantum TLS & Bidirectional TCP MSS Clamping — 2026-10-08

Modern browsers (Firefox 130+, Chrome 124+) enable Post-Quantum key exchange
(`X25519MLKEM768` / Kyber) by default, expanding TLS ClientHello to ~1540 bytes.
`tunnel.sh` previously only clamped outbound MSS (`-o tun0`). Inbound SYN-ACKs
from the server were unclamped, so LAN clients retained MSS 1460 and sent 1500-byte
IP packets. The router fragmented these over `tun0` (MTU 1280), and Cloudflare's
MASQUE edge desynchronized the second fragment, causing `SSL_ERROR_BAD_MAC_READ`
(e.g. on `opencode.ai`).
`tunnel.sh`, `stop_tunnel.sh`, and `ensure_network.sh` now install and maintain
bidirectional MSS clamping (`--set-mss 1240` IPv4, `--set-mss 1220` IPv6 on
`-i tun0`).

## Client events, firewall hook and locking — 2026-10-22

- `usque-rs --syslog` (passed by `tunnel.sh` when supported) logs connection
  events and why each session ended: `logread -e usque-rs`. The client also
  detects a dead path (90 s idle timeout), backs off after short sessions,
  deletes its PEM files once loaded, and ends a session whose TUN writes keep
  failing.
- `firewall_hook.sh` (fw3 include `firewall.router_script`, registered by
  `install_firewall_hook.sh`) starts a health check right after fw3 rebuilds the
  firewall; `fw3 restart` removes every rule router-script adds.
- `defaults.sh` holds every default more than one script uses; source it after
  `.env`. The health check also checks platform assumptions once per boot.
- Game mode no longer toggles `filter_aaaa` (dnsmasq 2.85 ignores it); its IPv6
  REJECT is what hides IPv6.
- `measure_load_latency.sh` measures round trips through WARP under load;
  `WARP_TUN_BACKPRESSURE` turns on the client's TUN-read backpressure.
- See `audit/2026-10-20-full-review/REPORT.md` §19.

## Router clock and the Google IPv6 policy — 2026-10-25

- GL.iNet 4.11.0 (upgraded on 25 October) keeps time with chrony, using NTS
  sources from `/etc/config/chrony`. There is no RTC, so after a power cut the
  clock restarts from the newest file under `/etc` until chrony corrects it.
- The health check warns when the clock and a direct probe's `Date` header
  differ by more than 120 s; it compares them every 10 minutes of uptime.
- `google_wan_policy.sh` rejects only the LAN's IPv6 traffic to Google; the
  router's own goes through WARP. It keeps those rejects above the LAN→`tun0`
  ACCEPT that `tunnel.sh` and the health check insert.
- See `audit/2026-10-20-full-review/REPORT.md` §21.

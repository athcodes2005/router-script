# IITB OpenWrt Router Scripts

Deployment bundle for a GL.iNet GL-MT3000 router in an IITB hostel room.

## Network Design

### Traffic routing
- **Public IPv4 default**: through `tun0` (WARP tunnel)
- **Public IPv6 default**: through `tun0` (WARP tunnel)
- **Campus private** (`10.0.0.0/8`): directly through `eth0`
- **WARP transport endpoints**: directly through `eth0` to avoid routing loops

### DNS chain (strict-order)
1. `8.8.8.8` (Google primary)
2. `8.8.4.4` (Google secondary)
3. `10.200.1.11` (campus resolver)
4. `127.0.0.1#5453` (dnscrypt-proxy DoH — last resort)

Campus-specific domains (`internet.iitb.ac.in`, `sso.iitb.ac.in`,
`cc.iitb.ac.in`, `moodle.iitb.ac.in`, `portal.iitb.ac.in`,
`mulyankan.cse.iitb.ac.in`, and `webmail.iitb.ac.in`) go directly to
`10.200.1.11`. Only these hosts are forwarded, never the whole `iitb.ac.in` zone.

### LAN IPv6 path
- LAN clients receive a ULA prefix from `br-lan`
- Router advertises itself as IPv6 default gateway (`ra_default=2`)
- NAT66 masquerades LAN IPv6 traffic out through `tun0`

## Files

### Runtime scripts
- `login.sh` — captive portal authentication
- `tunnel.sh` — start WARP as the full public IPv4/IPv6 gateway
- `stop_tunnel.sh` — stop tunnel and revert routes
- `firewall_hook.sh` — fw3 include: a health check right after fw3 rebuilds the firewall

### Shared helpers (sourced)
- `paths.sh` — log and diagnostics locations
- `defaults.sh` — every default more than one script uses (after `.env`, so `.env` wins)
- `lock.sh` — the maintenance lock: owner-aware, never taken from a live owner by age

### Configuration scripts
- `configure_wifi.sh` — enforce India regulatory domain and stable channel widths
- `configure_dns.sh` — set up dnsmasq multi-server DNS + campus forwarding
- `configure_lan_ipv6.sh` — enable LAN IPv6 advertisements and DHCPv6
- `ensure_network.sh` — health-check pipeline (DNS, login, tunnel, IPv6)
- `install_cron_pipeline.sh` — install recurring cron jobs
- `install_firewall_hook.sh` — register `firewall_hook.sh` as fw3 include `firewall.router_script`
- `bootstrap_router.sh` — one-shot setup entrypoint

### Diagnostic scripts
- `diagnose.sh` — full connectivity/routing/DNS/firewall diagnostics
- `collect_diagnostics.sh` — save timestamped diagnostic report (`--emergency` for emergency prefix)
- `dns_flow.sh` — show active DNS listeners, config, and live tests
- `download_emergency_diagnostics.sh` — from Mac: run emergency capture on router and download
- `measure_load_latency.sh` — round trips through WARP idle and under upload/download load
- `logread -e usque-rs` — the WARP client's connection events and why sessions ended

### Utility scripts
- `sync_to_router.sh` — push local files to router (staged with a manifest, then `promote_staged.sh`)
- `promote_staged.sh` — runs on the router: verifies the stage, promotes it under the lock
- `sync_from_router.sh` — pull runtime state from router
- `rotate_logs.sh` — rotate logs and trim old diagnostics
- `rotate_tunnel_ip.sh` — re-register WARP for fresh IP

### Data files
- `blocked_sites.txt` — legacy split-routing data, retained for rollback
- `warp_clients.txt` — legacy per-client routing data, retained for rollback
- `usque-rs` — optimized Cloudflare WARP MASQUE client binary
- `usque-rs-upstream-v0.1.0` — previous binary retained for rollback (deployed by `sync_to_router.sh`)
- `usque-rs-optimized/` — source and reproducible ARM64 OpenWrt candidate
- `.env` — credentials
- `config.json` — usque-rs registration

## Setup

```sh
./sync_to_router.sh
ssh root@192.168.8.1
cd /root/router-script
./bootstrap_router.sh
```

## Cron Pipeline

```
*/1 * * * *    ensure_network.sh
*/1 * * * *    sleep 30; ensure_network.sh
17 */6 * * *   collect_diagnostics.sh
47 */6 * * *   rotate_logs.sh
```

Tunnel recovery is bounded: if a restart still fails, the router removes the
dead tunnel routes, keeps direct IPv4 WAN available, and waits five minutes
before retrying WARP. This avoids minute-by-minute restart loops.

The launcher waits for an explicit CONNECT-IP readiness marker before installing
public default routes. The health pipeline separately checks Ethernet carrier,
DHCP, radio runtime, dnsmasq/campus DNS, tunnel readiness, both address families,
and campus exceptions so a failure is repaired at its actual layer.

The QUIC event loop enforces a 5 ms minimum timer delay to prevent expired
loss-recovery timers from spinning at 100% of one CPU core. Active TUN and UDP
events are unaffected and still wake immediately.

The Wi-Fi stability profile uses the India regulatory domain, 20 MHz on 2.4 GHz,
and 80 MHz on 5 GHz. These widths reduce interference and client compatibility
problems while retaining far more throughput than the campus uplink requires.

## Campus Exceptions

Campus DNS resolves `internet.iitb.ac.in`, `sso.iitb.ac.in`,
`moodle.iitb.ac.in`, `portal.iitb.ac.in`, and
`cc.iitb.ac.in` to addresses in `10.0.0.0/8`. That private range and IITB's
public `103.21.124.0/22` stay directly routed through `eth0`; other public
destinations use WARP. Named split-horizon sites are also resolved dynamically
and installed as `/32` direct-WAN exceptions. Additional campus-private ranges
and public hostnames can be supplied with the space-separated `CAMPUS_NETS` and
`CAMPUS_DIRECT_DOMAINS` environment settings.

## `.env` Configuration

Required:
```env
USER=your_ldap_id
PASS=your_internet_access_token
```

`.env` and `config.json` contain credentials/private keys and must remain mode
`0600`. The sync and tunnel launchers enforce this on both Mac and router.

Optional tunnel tuning:

```env
# cubic (binary fallback), bbr, bbr2, or reno
WARP_CC=bbr2
```

The optimized Rust client uses bounded forwarding batches, honors quiche packet
pacing deadlines, reuses its receive buffer, and samples QUIC statistics
outside the per-packet hot path. The executable retains CUBIC as its fallback,
but the active hostel deployment explicitly selects BBR2: same-path testing on
2026-08-09 showed CUBIC rapidly collapsing and pinning a CPU core, while BBR2
kept transfers consistent with an empty UDP receive queue.

To roll back on the router (deploys before 2026-10-22 did not ship the
rollback binary, so check that `usque-rs-upstream-v0.1.0` exists first):

```sh
ls -l usque-rs-upstream-v0.1.0
./stop_tunnel.sh
cp usque-rs-upstream-v0.1.0 usque-rs
chmod 755 usque-rs
./tunnel.sh
```

The launcher detects whether the selected binary supports congestion-control
selection, so the upstream rollback binary remains compatible.

## Troubleshooting

### If login stops working
- Run `./login.sh` and check `logs/login.log`
- Token login follows IITB's HTTPS redirect chain with trusted Basic Auth, as
  required by the institute's headless-login flow.
- If the token is expired or revoked, generate a new CC Internet Access token.
  If automatic login still fails, complete SSO interactively at
  `https://internet.iitb.ac.in/login.php`; WARP restarts automatically afterward.

### If DNS stops working
- Run `./dns_flow.sh`
- Verify `8.8.8.8` is reachable: `ping -c 3 8.8.8.8`

### If IPv6 stops working
- Check tunnel: `pidof usque-rs`
- Check routes: `ip -6 route show default`
- Run `./diagnose.sh`

### If the whole connection becomes sluggish or unavailable
- Run `./collect_diagnostics.sh --emergency` before restarting anything.
- `diagnose.sh` records exact direct/WARP HTTP probes, the WARP readiness marker,
  Ethernet carrier, live radio state, filesystem pressure, and campus host routes.
- Project diagnostics retain 24 snapshots. If persistent storage reaches 97%,
  new project logs and diagnostics use `/tmp` instead of exhausting overlay.

### Emergency capture from Mac
```sh
cd /Users/atharva/projects/router-script
./download_emergency_diagnostics.sh
```

## Context Files

- `PROJECT_CONTEXT.md` — architecture, known fixes, debugging prompts
- `README.md` — this file
- `wiki-llm/wiki/index.md` — complete model-oriented codebase and operations map

## Intermittent game latency

The 2026-09-19 audit found 12 watchdog tunnel restarts in the previous day's
logs and several campus-login recoveries. Their exact relationship to game
spikes was not captured. Health checks now log a failure reason, confirm a
live-client failure before restarting, and refresh optional DNS routes without
restarting WARP. See [audit results](audit/2026-09-19/REPORT.md).

For a bounded, read-only capture on the router:

```sh
DURATION=60 INTERVAL=5 PHONE_IP=<current-device-LAN-IP> sh monitor_game_network.sh
```

Omit `PHONE_IP` to capture only gateway, direct WAN, and WARP. Client ping loss
can reflect device sleep; HTTP duration is not game-server RTT. Change game
mode only between matches because changing the public route can interrupt
existing sessions. `game_mode.sh on` selects direct IPv4; `off` restores WARP.

## Blinkit VPN warning

Blinkit's known API endpoints now receive refreshed IPv4-only DNS answers and
use the direct campus WAN. Other domains keep IPv6 through WARP. The updater
installs routes before publishing answers and keeps saved addresses during DNS
outages. After this change, force-close Blinkit and reconnect the phone's Wi-Fi
once to refresh cached DNS. See the
[incident notes](wiki-llm/wiki/bugs/blinkit-ipv6-vpn-warning-2026-09-19.md).

## Post-Quantum TLS & Bidirectional TCP MSS Clamping

Modern browsers (Firefox 130+, Chrome 124+) enable hybrid Post-Quantum key exchange
(`X25519MLKEM768`) by default, expanding TLS `ClientHello` packets to ~1540 bytes.
`tunnel.sh`, `stop_tunnel.sh`, and `ensure_network.sh` enforce bidirectional TCP MSS
clamping (`--set-mss 1240` IPv4, `--set-mss 1220` IPv6 on `tun0` ingress) to prevent
IP fragmentation over the 1280-byte WARP tunnel and avoid `SSL_ERROR_BAD_MAC_READ`.
See [incident notes](wiki-llm/wiki/bugs/opencode-pqc-mss-clamping-2026-10-08.md).

# LAN IPv6 repair-loop outage — 2026-08-13

Internet recovery stopped after a router restart even though the campus uplink
and direct public IPv4 access were healthy. The health pipeline was trapped in
its LAN IPv6 prerequisite and never reached portal or WARP recovery.

## Evidence

- The router had been up for about eight hours and retained its WAN IPv4 lease.
- The campus gateway averaged about `0.78 ms` with zero loss.
- Direct WAN probes returned HTTP `204` in about `57–116 ms`.
- WARP had no process, readiness marker, or tunnel default route.
- Beginning at 06:47, every health run reported missing global LAN IPv6,
  invoked `configure_lan_ipv6.sh`, reloaded `lan`, failed its postcondition, and
  exited. The pattern continued at every scheduled start and midpoint minute.
- Each `ifup lan` dismantled and recreated `br-lan`, briefly taking both radios
  down. This made Wi-Fi appear unstable and repeatedly interrupted management.

## Root cause

The vendor OpenWrt `netifd` runtime retained the configured ULA prefix
assignment but exposed an empty `local-address` after restart. Consequently,
`br-lan` had no global-scope IPv6 address. The configuration script only set
`ip6assign` and `ip6ifaceid`; it did not install an explicit ULA address.

The health pipeline treated failed LAN IPv6 repair as fatal and exited before
WAN authorization and WARP startup. Because no cooldown existed for this repair,
the twice-per-minute watchdog repeated the disruptive LAN reload indefinitely.

## Permanent repair

- `configure_lan_ipv6.sh` derives a stable `/64` address from the configured ULA
  `/48` and persists it as `network.lan.ip6addr`.
- The script explicitly enables IPv6 before interface configuration instead of
  depending on the later tunnel launcher to do so.
- `ensure_network.sh` rate-limits failed LAN IPv6 repair for five minutes,
  captures evidence once, and continues IPv4 authentication and WARP recovery.
- A successful postcondition clears the cooldown marker.

## Verification

- Shell syntax and ShellCheck passed; router-side hashes matched local files.
- One controlled reload installed the global ULA on `br-lan` and restored client
  SLAAC plus the advertised default route.
- WARP restarted with BBR2; process and readiness PIDs matched.
- Consecutive watchdog runs passed without another LAN reload.
- Wi-Fi-bound client probes returned HTTP `204` for IPv4 and IPv6 in about
  `42 ms`; direct campus, campus DNS, and tunnel routing also passed.
- Timestamped rollback copies were retained on the router until 2026-10-22,
  when they were archived off the router and removed ([[../log]]). No Mac configuration
  was modified.

## Related pages

See [[../systems/ipv6]], [[../operations/health-recovery]], and
[[../flows/boot-and-recovery]].

## Sources

- Live router UCI, interface, syslog, health-log, and connectivity inspection on 2026-08-13.
- `../../../configure_lan_ipv6.sh`
- `../../../ensure_network.sh`
- `../../../tunnel.sh`

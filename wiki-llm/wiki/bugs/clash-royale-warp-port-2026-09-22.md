# Clash Royale Wi-Fi failure — 2026-09-22

Clash Royale worked over a mobile hotspot but failed on the iPad over router
Wi-Fi.

## Evidence

- The iPad was identified from its current DHCP lease; capture was limited to
  DNS and packet headers.
- DNS queries included `game.clashroyaleapp.com`, `id.supercell.com`,
  `init.mkt.supercell.com`, and Sentry telemetry.
- The game repeatedly retransmitted TCP SYNs to `44.252.91.204:9339` while the
  normal default route was `tun0` (WARP).
- During the follow-up lag report, dynamic UDP/9339 endpoints such as
  `44.243.105.81` and `44.250.50.14` still selected `tun0`; their conntrack
  replies were mapped to the WARP address `172.16.0.2`.
- Before repair, a TCP test to that port timed out through WARP but connected
  through the physical campus WAN in under one millisecond. An empty reply is
  expected because port 9339 is not HTTP.

## Root cause

The WARP path could not reliably reach the Supercell game-session port, even
though ordinary HTTPS and DNS were healthy. DNS-derived host routes alone were
insufficient because Supercell changes the session IPs and an existing
conntrack flow stays on the path selected for its first packet. This was a
path/port compatibility issue, not an iPad or Wi-Fi radio problem.

## Repair

- Added the observed Clash Royale/Supercell hostnames to `DIRECT_PUBLIC_DOMAINS`.
- Dynamic IPv4 host routes now send the current AWS game addresses through the
  campus WAN and refresh them during tunnel startup and health maintenance.
- Added a narrow policy-routing rule for TCP/UDP port `9339`: new and existing
  conntracked game sessions use routing table `101` and the campus WAN from
  the first packet. The dynamic host-route refresher remains as a fallback.
- Verified all current `game.clashroyaleapp.com` addresses select `eth0` and the
  normal router health pipeline passes.
- No iPad or Mac network settings were changed.

## Sources

- Bounded iPad packet-header capture and direct/WARP port tests on 2026-09-22.
- `../../../tunnel.sh`
- `../../../ensure_network.sh`

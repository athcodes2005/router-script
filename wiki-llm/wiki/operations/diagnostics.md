# Diagnostics and retention

Diagnostics are designed for bounded, point-in-time evidence rather than
continuous packet capture. This distinction matters because router `/tmp` is a
RAM-backed filesystem shared with active services.

## Snapshot content

`diagnose.sh` reports interfaces, Ethernet carrier, live radio state, IPv4/IPv6
routes, dynamic campus host routes, firewall/NAT, process and CONNECT-IP-ready
state, DNS configuration, recent logs, memory, filesystem usage, and the largest
immediate `/tmp` entries. Exact probes distinguish direct IPv4 and WARP IPv4
(`204` from Google) and WARP IPv6 (`200` from Cloudflare's trace by IP literal,
which no Google policy touches). It identifies tcpdump
processes so abandoned captures are visible.
Wireless status embeds WPA passphrases, so its key, password, secret and PSK
values are redacted before they are recorded.

Legacy policy-routing and blocklist sections are labeled as legacy to avoid
confusing their absence with a fault in the active full-tunnel architecture.

## Collection

The health pipeline takes at most one failure snapshot per reason (Wi-Fi, DNS,
WAN lease, campus route, internet, `/tmp` pressure, tunnel restart, ...) per
`DIAGNOSTICS_COOLDOWN` (15 minutes), so a long outage keeps its first snapshot
instead of replacing the retained history every tick.

`collect_diagnostics.sh` creates names containing both a timestamp and process
ID, preventing collisions between events in the same second. Snapshots are
written with mode `0600`. Snapshots taken before this redaction was deployed
contain Wi-Fi passphrases in plain text and should be treated as secret. It retains 24
normal and 24 emergency snapshots by default. `download_emergency_diagnostics.sh`
uses bounded SSH/SCP sessions to transfer evidence to the workstation.

## Log handling

`paths.sh` selects persistent log locations and moves new project output to
`/tmp` if the project filesystem is at least 97 percent used or unwritable.
`rotate_logs.sh` bounds size, generations, and snapshot counts (including
`latency.log` from `measure_load_latency.sh`); cron invokes it
every six hours. Tunnel status rendering is redirected away from persistent
flash because it rewrites a line continuously.

## Game latency sampling

`DURATION=60 INTERVAL=5 PHONE_IP=<device-lan-ip> sh monitor_game_network.sh`
records gateway/client packet loss and min/average/max RTT alongside simultaneous,
interface-bound WAN/WARP HTTP status and duration. `PHONE_IP` is optional; choose
it from current device settings, not historical leases. Sleeping Apple devices
may ignore ICMP, so no reply alone does not prove a Wi-Fi failure.

The gateway is discovered from the current WAN route. Runtime is measured by
wall time (the final bounded probe can extend it by up to three seconds). Logs
rotate at 1 MiB and participate in regular maintenance. HTTP duration includes
DNS/TCP/TLS and is not equivalent to in-game ping. Snapshot diagnostics also
record queue/link counters to help investigate congestion.

## Safety

Packet captures are never started by the health pipeline. If a manual capture
is required, use a size or packet limit, record its PID and output path, and
remove both after inspection. Treat captures and snapshots as sensitive.

## Sources

- `../../../diagnose.sh`
- `../../../collect_diagnostics.sh`
- `../../../download_emergency_diagnostics.sh`
- `../../../rotate_logs.sh`
- `../../../paths.sh`
- `../../../monitor_game_network.sh`

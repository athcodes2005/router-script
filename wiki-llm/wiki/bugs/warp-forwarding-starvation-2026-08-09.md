# WARP forwarding-starvation incident — 2026-08-09

Public traffic became sluggish while the campus uplink remained healthy. This
was a second event-loop failure, distinct from the zero-duration timer spin
repaired on 2026-08-07.

## Evidence before repair

- The hostel gateway had zero loss and `0.87 ms` average latency.
- Direct campus-path HTTPS completed in `71–82 ms`.
- The same probe through WARP required `1.5–4.2 s`.
- `usque-rs` consumed 968 CPU ticks in ten seconds, effectively one full core.
- The WARP UDP socket retained 135,936 bytes in `Recv-Q` while `tun0` received
  only about 363,398 bytes/s.
- The launcher was installing files as well as downloading, but the router
  measurements proved an independent WARP forwarding bottleneck.

## Root cause

After each selected TUN, UDP, or timer event, the established-session loop used
an unbounded `socket.try_recv()` loop to drain all queued WARP packets. During
continuous incoming traffic the socket could remain readable indefinitely.
That allowed UDP/QUIC intake to monopolize the runtime before the later stages
could poll HTTP/3, extract CONNECT-IP datagrams, write them to `tun0`, or flush
outbound QUIC acknowledgements. The result was a full-core loop, a persistent
kernel UDP backlog, and very low useful client throughput.

Fair batching removed the permanent receive-stage monopoly, but a same-day
soak exposed a second coupled defect: the client ignored quiche's
`SendInfo::at` pacing deadlines. CUBIC packets scheduled for future delivery
were sent immediately, causing bursts, loss recovery, high CPU, and congestion
window collapse. A controlled comparison measured about `51 Mbps` directly and
only `4.2 Mbps` through the degraded WARP session.

## Permanent repair

- Limit each UDP intake, HTTP/3 poll, CONNECT-IP receive, and QUIC send stage to
  64 items per pass.
- Schedule a cooperative continuation when a batch reaches its limit, allowing
  ready socket and TUN branches to compete fairly between bounded passes.
- Retain the five-millisecond quiche timer floor from the earlier repair.
- Hold future-scheduled QUIC packets until `SendInfo::at` while continuing to
  service TUN, UDP, timeout, and cooperative-work events.
- Persist BBR2 as the congestion controller. On the live campus path CUBIC
  collapsed from about `10.5` to `4.6 Mbps` across two short transfers and used
  471 CPU ticks in five seconds. BBR2 remained consistent with two CPU ticks
  and an empty receive queue in the same controller benchmark.
- Add three health-check performance samples. Two failed probes or two samples
  exceeding 1.5 seconds make the session unhealthy, so the minute watchdog can
  recover a tunnel that is reachable but unusably slow. *(Historical: removed on
  2026-09-19 because latency caused false restarts. Since 2026-10-22, three
  consecutive probes over 1.5 s log a warning and one snapshot, with no restart;
  see [[../operations/health-recovery]].)*

## Verification after deployment

- ARM64 Linux validation passed strict Clippy, 44 unit tests, 23 integration
  tests, formatting, ShellCheck, and shell syntax checks.
- Deployed binary SHA-256:
  `1ee312fc8c64de8a06015034215b9bc0226457e8ac1959d6a1b933c4a194c7e9`.
- Under live client traffic, CPU fell to 42 ticks per ten seconds and UDP
  `Recv-Q` fell to zero.
- After a full minute of continuous transfer, settled CPU was 13 ticks per ten
  seconds, the queue remained zero, and five HTTPS probes took `69–75 ms`.
- IPv4, IPv6, readiness PID, gateway reachability, campus DNS routing,
  Computer Centre routing, and the complete health pipeline passed.
- Before final pacing/controller correction, the client measured `5.7 Mbps`
  down, `11.4 Mbps` up, and `154 ms` idle latency. With paced BBR2 it measured
  `66.0 Mbps` down, `40.2 Mbps` up, and `19 ms` idle latency.
- A final 48 MB soak completed six consecutive transfers without failure;
  settled CPU was 45 ticks per ten seconds and UDP `Recv-Q` remained zero.
- The former binary and health script remained on the router as explicit
  rollback copies, including the pre-pacing build, until 2026-10-22. They were
  then archived off the router and removed ([[../log]]). The documented binary
  rollback is `usque-rs.prev` (legacy name `usque-rs-upstream-v0.1.0`).

## Related pages

See [[warp-cpu-spin-2026-08-07]], [[../systems/warp-client]], and
[[../operations/health-recovery]].

## Sources

- Live router measurements on 2026-08-08 and 2026-08-09.
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/src/tunnel.rs`
- `../../../ensure_network.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/tests/tunnel_mtu.rs`

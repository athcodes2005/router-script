# WARP CPU-spin incident — 2026-08-07

Internet access felt sluggish even though the physical campus uplink and Wi-Fi
could sustain high throughput. The fault was isolated to the userspace WARP
event loop and two recovery behaviors that amplified transient failures.

## Evidence before repair

- Hostel gateway latency was `0.816 ms` with zero loss.
- Direct campus-path throughput was about `110 Mbps`.
- Direct HTTPS completed in roughly `70–80 ms`.
- WARP HTTPS required `0.7–1.3 s`, and sustained WARP downloads sometimes
  terminated the diagnostic SSH session.
- `usque-rs` used 961 CPU ticks in ten seconds: essentially one complete core.
- The tunnel carried only about `1.7 Mbps` and 253 packets/s during that sample,
  ruling out legitimate saturation as the reason for full-core CPU use.
- The health log recorded 21 direct-internet recovery events and three tunnel
  failures that day, including two restarts within two minutes.

## Root cause

quiche can return a zero-duration connection timeout while loss recovery is
pending. The established-session loop passed that value directly to
`tokio::time::sleep`. Repeated zero-duration sleeps formed a hot loop, consuming
the CPU time needed for packet processing and increasing tunnel latency.

Health recovery also evaluated the complete live tunnel check multiple times in
separate conditionals. A flapping probe could fail, pass before the restart
branch, then fail again and be reported as unhealthy “after restart” even though
no restart occurred. Direct probe transients could likewise initiate portal
logout too quickly.

## Repair

- Floor established-session timer sleeps at five milliseconds.
- Keep socket and TUN reads in the same `select`, so active traffic is not
  delayed by the timer floor.
- Add a unit test covering zero, sub-floor, normal, absent, and capped timers.
- Evaluate tunnel health once before recovery and once after an actual restart.
- Confirm direct failure twice before invoking portal recovery.
- Recheck public access three times after token login before forced logout.

## Verification after deployment

- Idle WARP CPU fell to zero in repeated `top` samples.
- A settled ten-second sample used 26 CPU ticks instead of 961.
- Five tunneled HTTPS probes completed in `72–82 ms`.
- Router-side WARP throughput reached about `139 Mbps`.
- Wi-Fi client throughput reached about `96 Mbps` with zero LAN loss.
- IPv4, IPv6, campus routing, portal state, DNS `20/20`, readiness PID, and the
  complete health pipeline all passed.
- ARM64 validation passed 42 unit tests, 23 integration tests, strict Clippy,
  formatting, ShellCheck, and BusyBox-compatible syntax checks.

## Related pages

See [[../systems/warp-client]], [[../operations/health-recovery]], and
[[known-issues]].

## Sources

- Live router and Wi-Fi-client measurements on 2026-08-07.
- `../../../usque-rs-optimized/src/tunnel.rs`
- `../../../ensure_network.sh`
- `../../../login.sh`

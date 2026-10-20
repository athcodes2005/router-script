# Rust WARP MASQUE client

`usque-rs-optimized` is a Linux/OpenWrt-oriented asynchronous Rust program. It
registers a WARP device or exposes WARP as a native TUN using CONNECT-IP over
HTTP/3 and QUIC.

## Modules

- `main.rs`: CLI, registration workflow, TUN startup, and option validation.
- `config.rs`: config schema, decoding, atomic persistence, and peer selection.
- `register.rs`: Cloudflare API calls and EC key-pair generation/enrollment.
- `tls.rs`: client certificate construction and endpoint SPKI verification.
- `tun_device.rs`: Linux TUN creation and address configuration.
- `tunnel.rs`: QUIC/H3 handshake, CONNECT-IP session, retry, stats, and I/O loop.
- `packet.rs`: IPv4/IPv6 parsing, checksums, and packet rewrite helpers.
- `icmp.rs`: ICMP Packet Too Big / Fragmentation Needed generation.

## Registration lifecycle

Registration obtains account data, rejects responses without a peer, creates a
P-256 device key, enrolls it for MASQUE, and atomically persists mode-`0600`
configuration beside the requested target path. HTTP connect and total request
timeouts prevent indefinite enrollment hangs.

## Tunnel lifecycle

The process creates `tun0` and immediately opens the QUIC/HTTP3 session; it does
not wait for a client packet. Handshake and CONNECT response phases each have a
hard deadline. The endpoint must present a certificate whose public key matches
the WARP-provided SPKI pin. After CONNECT-IP succeeds, the process
writes a PID readiness marker. `tunnel.sh` waits for that marker before replacing
the public default routes, and removes partial state if startup fails.

An explicit QUIC ACK-eliciting frame is sent at the configured keepalive period;
the former timer merely woke the loop and generated no traffic. A scoped task
guard aborts the statistics task on every disconnect. Reconnect delay grows
from one to thirty seconds during repeated failures and resets after a session
that reached readiness.

The established-session event loop applies a five-millisecond floor to expired
quiche timers. Without that floor, a persistent zero-duration loss-recovery
timeout could turn `tokio::sleep(0)` into a hot loop, pinning one CPU core and
adding hundreds of milliseconds to tunneled connections. Socket and TUN events
still wake the loop immediately, so the floor does not throttle active traffic.

Every forwarding stage is also capped at 64 items per pass. UDP intake, HTTP/3
polling, CONNECT-IP delivery, and QUIC output therefore yield fairly to one
another even when the kernel socket remains continuously readable. A capped
stage schedules a cooperative continuation, so bounding a pass does not leave
internal QUIC work waiting for an unrelated external event.

QUIC output honors quiche's `SendInfo::at` pacing deadline. One future packet
is retained until its deadline and represented as a timer branch in the main
select loop, so receiving and TUN forwarding continue while output is paced.
Sending all packets immediately caused packet bursts and progressive CUBIC
congestion-window collapse on the campus UDP path.

The active deployment selects BBR2 through `WARP_CC` in `.env`. Live comparison
against CUBIC, BBR, and Reno showed that BBR2 kept the receive queue empty and
used the least CPU while maintaining consistent transfers. `tunnel.sh` still
defaults to CUBIC when the environment does not provide an explicit controller.

Packet parsing validates the full IPv4 header length and computes checksums over
IPv4 options as well as the base header. Malformed IHL values are rejected
instead of being sliced or checksummed incorrectly.

## Build and tests

The deployed artifact targets `aarch64-unknown-linux-musl`. The 2026-08-09 build
passed formatting, strict Clippy, 44 unit tests, and 23 integration tests under
the ARM64 Linux target. `tests/tunnel_mtu.rs` checks behavior around tunnel MTU.
Native macOS compilation is not a valid test because Linux TUN/netlink APIs are
required.

## Sources

- `../../../usque-rs-optimized/src/main.rs`
- `../../../usque-rs-optimized/src/config.rs`
- `../../../usque-rs-optimized/src/register.rs`
- `../../../usque-rs-optimized/src/tls.rs`
- `../../../usque-rs-optimized/src/tun_device.rs`
- `../../../usque-rs-optimized/src/tunnel.rs`
- `../../../usque-rs-optimized/src/packet.rs`
- `../../../usque-rs-optimized/src/icmp.rs`
- `../../../usque-rs-optimized/tests/tunnel_mtu.rs`

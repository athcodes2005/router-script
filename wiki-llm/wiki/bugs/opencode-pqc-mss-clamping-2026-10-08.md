# OpenCode Post-Quantum TLS handshake failure — 2026-10-08

Firefox and OpenSSL connections to `opencode.ai` and `api.opencode.ai` failed
with `SSL_ERROR_BAD_MAC_READ` / `decryption failed or bad record mac` through
WARP, while loading successfully over mobile data.

## Evidence

- Probing `opencode.ai` and `api.opencode.ai` directly through WARP using curl
  returned HTTP `200` OK ("Hello, world!"), proving WARP egress is not blocked.
- Modern browsers (Firefox 130+, Chrome 124+) and OpenSSL 3.6+ enable
  hybrid Post-Quantum key exchange (`X25519MLKEM768` / Kyber) by default.
  The ML-KEM public key material expands TLS `ClientHello` to ~1540 bytes.
- OpenSSL with classical `X25519` (<400-byte ClientHello) succeeded through WARP.
- OpenSSL with `X25519MLKEM768` succeeded through direct campus WAN (MTU 1500).
- `tcpdump` on the router captured that `tunnel.sh` clamped TCP MSS only for
  outbound SYN packets (`-o tun0`). Inbound SYN-ACK packets from `tun0` were
  not clamped, so the client received an unclamped MSS of 1460.
- When the client sent a 1460-byte TCP payload (1500-byte IP packet) for its
  ML-KEM ClientHello, the router fragmented it over `tun0` (MTU 1280) into two IP
  fragments (1224 bytes + 276 bytes). Cloudflare's MASQUE edge dropped or
  desynchronized the second fragment, causing record-layer decryption failure.

## Repair

- Added inbound TCP MSS clamping on `tun0` for IPv4 (`--set-mss 1240`) and IPv6
  (`--set-mss 1220`) in `tunnel.sh` and `stop_tunnel.sh`.
- Extended `ensure_network.sh`'s `nat_rules_ok` and added `ensure_nat_and_mss_rules`
  to verify and repair both outbound and inbound MSS clamping in-place.
- Deployed to the router with staged promotion and lock protection; WARP PID
  remained unchanged.
- Validated with live OpenSSL `X25519MLKEM768` handshakes, Python urllib requests,
  and 21 regression tests in `tests/test_network_recovery.py`.

## Sources

- Live router packet captures and OpenSSL/Python tests on 2026-10-08.
- `../../../tunnel.sh`
- `../../../stop_tunnel.sh`
- `../../../ensure_network.sh`
- `../../../tests/test_network_recovery.py`
- `../../../audit/2026-10-08-mss-clamping/`
- [[../architecture]]
- [[../flows/traffic-routing]]

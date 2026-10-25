# Router Post-Quantum TLS & Bidirectional MSS Clamping Audit — 2026-10-08

## Scope

Investigation and repair of `SSL_ERROR_BAD_MAC_READ` and TLS handshake failures
observed on `opencode.ai` and `api.opencode.ai` through Cloudflare WARP.

## Findings

1. **IP reputation / blocking ruled out**: Unauthenticated HTTP requests directly
   through `tun0` using curl returned HTTP `200` OK. Cloudflare is not blocking
   the WARP egress IP.
2. **Post-Quantum Cryptography trigger**: Modern browsers (Firefox 130+,
   Chrome 124+) and OpenSSL 3.6+ enable `X25519MLKEM768` (ML-KEM-768/Kyber) by
   default, producing a `ClientHello` of ~1540 bytes.
3. **Asymmetric TCP MSS clamping defect**: `tunnel.sh` clamped MSS only for
   outbound SYN packets (`-o tun0`). Inbound SYN-ACK packets from the server
   passing to the LAN (`-i tun0`) were not clamped. LAN clients retained MSS 1460
   and sent a 1500-byte IP packet.
4. **Packet fragmentation failure**: The router fragmented the 1500-byte packet
   into two IP fragments (1224 bytes + 276 bytes) to fit `tun0` (MTU 1280).
   Cloudflare's Anycast MASQUE edge does not reassemble or transport IP fragments
   reliably, causing record-layer authentication failure (`SSL_ERROR_BAD_MAC_READ`).

## Installed Changes

1. **`tunnel.sh`**:
   - Added `TUN_IPV4_MSS="${TUN_IPV4_MSS:-1240}"` and `TUN_IPV6_MSS="${TUN_IPV6_MSS:-1220}"`.
   - Added inbound TCP MSS clamping on `tun0` for both IPv4 and IPv6:
     `iptables -t mangle -I FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV4_MSS"`
     `ip6tables -t mangle -I FORWARD -i "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TUN_IPV6_MSS"`
2. **`stop_tunnel.sh`**:
   - Added matching cleanup loops for the inbound TCP MSS rules.
3. **`ensure_network.sh`**:
   - Updated `nat_rules_ok` to verify both outbound and inbound MSS clamping rules.
   - Added `ensure_nat_and_mss_rules` to repair missing rules in-place without restarting WARP.
4. **`tests/test_network_recovery.py`**:
   - Added unit tests for bidirectional MSS clamping verification and in-place repair.

## Validation

- Passed 21 Python regression tests locally.
- Staged deployment via `audit/2026-10-08-mss-clamping/deploy.py` under the router maintenance lock.
- SHA-256 and `sh -n` verification passed prior to promotion.
- Pre-existing WARP PID 18099 preserved throughout deployment and verification.
- Verified OpenSSL `X25519MLKEM768` handshakes succeed through WARP.
- Verified Python urllib loads `https://opencode.ai/console` (200 OK) and `https://api.opencode.ai/` ("Hello, world!").
- Scheduled health pipeline run passed (`Health check passed.`).

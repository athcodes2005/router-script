# Traffic-routing flows

## Public IPv4 from a Wi-Fi client

1. The client sends a packet to its LAN gateway on `br-lan`.
2. The destination does not match a configured direct-WAN exception.
3. The preferred IPv4 default selects `tun0`.
4. The router clamps TCP MSS bidirectionally (1280 IPv4 / 1260 IPv6 for `tun0` MTU 1320) and masquerades at `tun0`.
5. `usque-rs` carries the IP packet inside CONNECT-IP over QUIC.
6. The QUIC transport itself reaches the WARP endpoint through an explicit
   physical-WAN route, avoiding recursive tunneling.

## Public IPv6 from a Wi-Fi client

1. odhcpd supplies the client a ULA address and advertised default.
2. Google IPv6 is rejected for IPv4 fallback; otherwise the default is `tun0`.
   The router's own IPv6 traffic to Google is not rejected: it uses `tun0`.
3. Forwarding, MSS clamping, and IPv6 masquerade are applied.
4. WARP supplies public IPv6 egress and carries replies back to the LAN.

## IITB campus site

1. dnsmasq forwards the selected IITB name to campus DNS.
2. The answer is in campus-private IPv4 space.
3. `10.0.0.0/8` is more specific than the WARP default.
4. The packet exits directly through the WAN gateway on `eth0`.

For an IITB site whose client receives or caches a public answer, the IITB-owned
`103.21.124.0/22` route still selects the campus WAN. `tunnel.sh` additionally
installs resolved `/32` exceptions for named split-horizon services. This
preserves the campus source IP without adding client-side routing state.

## Router-originated WARP transport

Both default/current Cloudflare endpoint addresses have host routes via the WAN
gateway. The endpoint packet therefore never enters the tunnel it sustains.

## Invariants and checks

`ensure_network.sh` tests tunnel defaults, campus route selection, NAT, and live
IPv4/IPv6 HTTPS. Google matches combine published service prefixes and DNS-learned
addresses; see [[../systems/google-wan]]. Other exceptions use routes or game
port policy. Campus DNS selection remains domain based. The policy-routing rules
and mark bits, including GL.iNet's, are in [[../systems/policy-routing]].

## Sources

- `../../../tunnel.sh`
- `../../../configure_dns.sh`
- `../../../ensure_network.sh`
- [[architecture]]
- [[../systems/campus-wan]]
- [[../systems/policy-routing]]

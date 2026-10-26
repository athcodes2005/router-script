# Active architecture

The router uses WARP defaults with direct WAN exceptions for campus services,
selected apps and game sessions, and Google services. Google routing and IPv6
fallback are described in [[systems/google-wan]].

## Components

1. `login.sh` satisfies the IITB captive portal over the physical WAN.
2. `usque-rs` establishes MASQUE over QUIC to Cloudflare on the physical WAN.
3. `tunnel.sh` creates direct exception routes, forwarding, NAT, and defaults.
4. dnsmasq sends campus domains to campus DNS, pins portal/SSO addresses
   locally, and forwards other queries through the ordered upstream chain.
5. odhcpd advertises the router-provided IPv6 prefix and default to LAN clients.
6. `ensure_network.sh` continuously validates and repairs the complete system.

## Routing invariants

- `tun0` is the preferred IPv4 default.
- `tun0` is the IPv6 default.
- `192.168.8.0/24` remains connected to `br-lan`.
- `10.0.0.0/8` has a more-specific route through the WAN gateway on `eth0`.
- Hostel 01 uses DHCP pool `10.1.32.0/19`, gateway `10.1.40.250`, and campus
  DNS `10.200.1.11` for the documented router location.
- Explicit campus-only public hosts have narrow direct routes through `eth0`.
- Every configured/current WARP endpoint has a direct route through `eth0`.
- IPv4 and IPv6 LAN traffic is masqueraded when leaving `tun0`.
- `tun0` uses link MTU `1320` (`TUN_MTU`), and TCP MSS is clamped bidirectionally
  for traffic traversing `tun0` (1280 IPv4 / 1260 IPv6).

## Control-plane invariants

- The health pipeline owns a directory lock to prevent concurrent repair.
- Sync and WARP rotation cooperate with the same lock.
- Startup is idempotent: a live `usque-rs` process can have routes repaired.
- Public defaults are installed only after the client signals CONNECT-IP ready.
- A failed WARP recovery removes dead tunnel defaults and restores direct IPv4.
- Resource pressure triggers a bounded retry cooldown instead of restart thrash.

## Related pages

See [[flows/traffic-routing]], [[flows/boot-and-recovery]],
[[systems/campus-wan]], [[systems/dns]], and [[systems/ipv6]] for detailed paths.

## Sources

- `../../tunnel.sh`
- `../../stop_tunnel.sh`
- `../../ensure_network.sh`
- `../../configure_dns.sh`

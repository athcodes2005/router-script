# LAN and WARP IPv6

The physical campus WAN does not supply a generally usable delegated prefix for
the LAN. The router therefore advertises a stable ULA prefix to clients and
translates forwarded IPv6 traffic at the WARP interface.

## LAN configuration

`configure_lan_ipv6.sh` derives a stable `/64` address from OpenWrt's configured
ULA `/48`, persists it as an explicit `network.lan.ip6addr`, assigns it to
`br-lan`, and enables:

- odhcpd router advertisements in server mode;
- SLAAC;
- DHCPv6 server mode;
- explicit default-route advertisement;
- an interface identifier of `::1` by default.

## Forwarding path

`tunnel.sh` enables kernel IPv6 and forwarding, installs an IPv6 default on
`tun0`, permits LAN-to-tunnel forwarding, permits established return traffic,
masquerades at `tun0`, and clamps TCP MSS.

After tunnel state is installed, odhcpd is restarted so clients refresh their
default route promptly. The health script also restarts it after tunnel repair.

## Health invariants

The health check requires the expected UCI values, a global-scope LAN IPv6
address, an IPv6 tunnel default, IPv6 NAT, and a successful public IPv6 HTTPS
probe. Both address families must pass before WARP is considered healthy.

If LAN IPv6 repair fails, the health pipeline records one diagnostic and waits
five minutes before another disruptive attempt while it continues direct IPv4
and WARP recovery. A successful repair clears that cooldown.

## Failure behavior

Direct fallback primarily preserves IPv4 because the campus uplink lacks the
same routed IPv6 service. A stopped or failed WARP session may therefore remove
public IPv6 while keeping the Wi-Fi usable over direct IPv4.

## Sources

- `../../../configure_lan_ipv6.sh`
- `../../../tunnel.sh`
- `../../../stop_tunnel.sh`
- `../../../ensure_network.sh`

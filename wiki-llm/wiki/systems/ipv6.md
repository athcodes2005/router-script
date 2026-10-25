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

On GL.iNet 4.11.0, while GL.iNet's own IPv6 switch (`glipv6.globals.enabled`)
is off, `/etc/hotplug.d/iface/99-disable_ipv6` sets `disable_ipv6=1` on every
interface on every `ifup`, stripping `br-lan`'s address (audit F47).
`configure_lan_ipv6.sh` therefore re-enables IPv6 and adds the address after
`ifup lan`, before starting `odhcpd`. When only the runtime address is missing,
`ensure_network.sh` restores it in place without reloading the LAN (F48).

## Forwarding path

`tunnel.sh` enables kernel IPv6 and forwarding, installs an IPv6 default on
`tun0`, permits LAN-to-tunnel forwarding, permits established return traffic,
masquerades at `tun0`, and clamps TCP MSS.

After tunnel state is installed, `tunnel.sh` restarts odhcpd once so clients
refresh their default route promptly. Since 2026-10-20 the health script no
longer restarts it a second time after a tunnel repair.

## Health invariants

The health check requires the expected UCI values, a global-scope LAN IPv6
address, an IPv6 tunnel default, and the IPv6 NAT, MSS and LAN forwarding rules.
No IPv6 HTTPS probe gates health or triggers a restart: only IPv4 is probed
through `tun0`. `diagnose.sh` reports `warp_ipv6_status` from Cloudflare's trace,
and WARP rotation requires `warp=on` for both families
([[../operations/warp-rotation]]).

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
- `../../../diagnose.sh`, `../../../rotate_tunnel_ip.sh`

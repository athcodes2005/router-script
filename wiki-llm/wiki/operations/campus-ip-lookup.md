# Campus IP/HOP lookup and static-IP fallback

The IITB Computer Centre publishes a "Hostel IP/HOP Search" page. For any hostel
and wing/floor it gives the DHCP pool, subnet mask, gateway, DNS server and the
published hop sequence. Use it to validate the router's WAN state during
diagnostics, and as the source of values for a manual static IP when hostel DHCP
is down. This router's own values (Hostel 01, Wing 1, Floor 0,1) are kept in
[[systems/campus-wan]].

## Reachability

Page: `https://www.cc.iitb.ac.in/page/ip_hostel`. It is campus-internal:
`www.cc.iitb.ac.in` resolves to a private `10.x` address and is listed in
`CAMPUS_DIRECT_DOMAINS` (`defaults.sh`). It works only over the campus network,
not through WARP or from outside campus. If hostel DHCP is down the router has no
campus address and cannot reach it, so use the offline values in
[[systems/campus-wan]].

## Endpoint chain (verified 2026-10-26, no login or SSO needed)

1. The page POSTs `ID=&PrivateID=ip_hostel` to `/action.php`, which returns the
   hostel form (`.../ip_allocation/hostelSearch.php`) listing `Hostel 01`, ...
2. The page JS POSTs to `/content/formAction/hostelsearchaction.php`:

```sh
URL=https://www.cc.iitb.ac.in/content/formAction/hostelsearchaction.php
# wings/floors for a hostel (returns <option> tags)
curl -sS -X POST --data-urlencode 'Mode=GetWingFloors' \
  --data-urlencode 'Type=Hostel 01' "$URL"
# addressing for one wing/floor (returns JSON)
curl -sS -X POST --data-urlencode 'Mode=GetData' \
  --data-urlencode 'Type=Hostel 01' \
  --data-urlencode 'Wing=Wing 1, Floor 0,1' "$URL"
```

Use `--data-urlencode`: values contain spaces and commas. Wing strings must match
the option text exactly (e.g. `Wing 0`, `Wing 2 Left, Floor 0,1`).

## JSON fields

`GetData` returns `[{...}]` with: `Hostel No`, `WingFloor`, `IPStart`/`IPEnd`
(DHCP pool), `Base IP` and `Mask Bits` (prefix), `SubnetMask`, `SwitchIP` (HOP 1),
`Gateway` (HOP 2), `HOP 3`, `HOP 4`, `HOP 5` (campus core).

The DNS server is not in the JSON. The page JS uses a constant,
`intToIP(180879627)` = `10.200.1.11`, for every hostel.

## Compare with live router state (read-only, on the router)

```sh
ip -4 addr show eth0          # lease should be inside IPStart-IPEnd, mask matches
ip route show default         # via should equal Gateway
traceroute -n 10.200.1.11
traceroute -n 10.100.1.250
```

Published hops may differ from a live trace: the switch IP is L2 management, and
some devices do not answer TTL-expired. A missing hop alone is not a fault; see
[[systems/campus-wan]]. On 2026-10-26 the live JSON for Hostel 01 / Wing 1,
Floor 0,1 matched every value recorded there.

## Manual static-IP fallback (hostel DHCP down)

This changes live router config: **agents must get the owner's explicit approval
before applying it.** Values (offline, from [[systems/campus-wan]]): mask
`255.255.224.0`, gateway `10.1.40.250`, DNS `10.200.1.11`, pool
`10.1.32.0`-`10.1.63.255`.

1. Pick an address inside the pool that is unused. Never take another device's
   address: probe first with `arping -I eth0 -c 3 <candidate>` and `ping -c 3
   <candidate>`; both must get no reply.
2. Apply (requires owner approval). The repo sets `WAN_IF=eth0` (`defaults.sh`)
   but no script edits `network.wan`; confirm with `uci show network.wan` first.

```sh
uci set network.wan.proto='static'
uci set network.wan.ipaddr='<free-pool-address>'
uci set network.wan.netmask='255.255.224.0'
uci set network.wan.gateway='10.1.40.250'
uci set network.wan.dns='10.200.1.11'
uci commit network && /etc/init.d/network reload
```

3. Revert to DHCP once hostel DHCP returns (requires owner approval):

```sh
uci set network.wan.proto='dhcp'
uci delete network.wan.ipaddr; uci delete network.wan.netmask
uci delete network.wan.gateway; uci delete network.wan.dns
uci commit network && /etc/init.d/network reload
```

After either reload, expect side effects on firmware 4.11.0: GL.iNet's
`/etc/hotplug.d/iface/99-disable_ipv6` strips `br-lan`'s ULA and `tun0`'s IPv6
on every `ifup` (only a WARP restart restores `tun0`'s), and the campus portal
may require a fresh login; let `ensure_network.sh` run a tick and check its log.
See [[systems/ipv6]] and [[operations/portal-login]].

## Freshness

The endpoint was verified on 2026-10-26 and is an undocumented internal
interface that could change; re-verify before relying on it.

## Sources

- `https://www.cc.iitb.ac.in/page/ip_hostel` (campus-only; verified 2026-10-26)
- `../../../defaults.sh` (`WAN_IF`, `CAMPUS_DIRECT_DOMAINS`)
- `../../../ensure_network.sh` (WAN default-gateway handling)
- `../../../diagnose.sh` (WAN evidence collection)
- [[systems/campus-wan]]

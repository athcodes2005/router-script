# Hostel 01 campus WAN

This page records the IITB Computer Centre `Hostel IP/HOP Search` result for
Hostel 01, Wing 1, Floors 0 and 1. Treat it as the authoritative physical-WAN
profile for this router location, not as a universal configuration for every
hostel or wing.

## Addressing

| Field | Value |
| --- | --- |
| DHCP pool | `10.1.32.0`–`10.1.63.255` |
| Subnet mask | `255.255.224.0` (`/19`) |
| Default gateway | `10.1.40.250` |
| Campus DNS server | `10.200.1.11` |

The WAN interface should obtain its address by DHCP within this pool. The
router must not hard-code a particular lease address, but the gateway and
campus DNS values are useful validation targets.

## Published hop sequence

| Hop | Role | Address |
| --- | --- | --- |
| 1 | Switch IP | `10.1.40.251` |
| 2 | Gateway | `10.1.40.250` |
| 3 | Campus hop | `10.250.1.1` |
| 4 | Campus hop | `10.250.3.1` |
| 5 | Campus hop | `10.100.1.250` |

This is the sequence published by the Computer Centre page. A live traceroute
may omit or reorder devices that do not emit TTL-expired replies, so absence of
a listed hop is not by itself evidence of a routing fault.

## Live interpretation on 2026-08-01

The router held a DHCP lease inside the documented `/19`; its exact address is
deliberately not fixed in policy. Both `10.1.40.250` and `10.1.40.251` were
visible by ARP. The switch address is management/control-plane identity on the
local L2 segment, so the first routed TTL hop is the gateway `.250`, not
necessarily the published switch address.

Traceroute toward campus DNS observed `.250`, `10.250.1.1`, intermediate
`172.16.6.2`/`172.16.5.1`, `10.250.201.2`, and `10.201.23.1`. A trace toward
`10.100.1.250` observed `.250`, `10.250.1.1`, the same `172.16` transit pair,
then the target. These paths are compatible with a routed campus core whose
internal links and ICMP responses differ by destination; they do not invalidate
the Computer Centre reference.

Campus DNS provides split-horizon answers: the access portal, SSO, Moodle, ASC,
and Computer Centre resolve into `10.0.0.0/8`, while public DNS can return
addresses in IITB's `103.21.124.0/22`. Selected campus names had no AAAA answers,
so their exception path is IPv4. Public IPv6 remains entirely WARP-provided.

Portal and SSO internal addresses verified on 2026-08-19 (and pinned in DNS
policy): `internet.iitb.ac.in` = `10.201.250.201`, `sso.iitb.ac.in` =
`10.200.1.100`. During that outage the room path through published hop
`10.250.1.1` was unhealthy while a corridor path via `10.250.201.2` stayed
usable; spoofing corridor identity is not a viable repair because return traffic
follows the room port. See [[../bugs/campus-dns-outage-2026-08-19]].

## Router policy implications

- `10.0.0.0/8` must remain directly routed through the physical WAN on `eth0`.
- IITB's public `103.21.124.0/22` must also remain direct so cached public
  split-horizon answers retain a campus source address.
- Campus DNS queries for selected IITB domains go to `10.200.1.11`.
- The WARP transport endpoints need their own direct routes through
  `10.1.40.250`, preventing recursive tunnelling.
- Named split-horizon sites retain resolved host exceptions in addition to the
  IITB public prefix; clients require no routes or service-order changes.
- Public IPv4 and IPv6 continue to use WARP unless an explicit campus exception
  applies.

## Related pages

See [[../architecture]], [[dns]], and [[../flows/traffic-routing]].

## Sources

- `../../raw/assets/hostel-01-network-config-2026-08-01.png` — user-supplied
  IITB Computer Centre screenshot captured 2026-08-01.
- `../../../tunnel.sh`
- `../../../configure_dns.sh`
- `../../../ensure_network.sh`

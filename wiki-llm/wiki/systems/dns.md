# DNS system

dnsmasq on the router is the LAN resolver and forwarding policy point. Its
configuration is deterministic: `noresolv=1` prevents dynamically supplied WAN
resolvers from silently bypassing the configured chain.

## Upstream policy

The expected server list contains Google IPv4 resolvers, the IITB campus DNS
server, and dnscrypt-proxy2 on `127.0.0.1#5453`. dnsmasq uses strict ordering.

Selected campus names are explicitly forwarded to campus DNS:

- `internet.iitb.ac.in`
- `sso.iitb.ac.in`
- `cc.iitb.ac.in`
- `moodle.iitb.ac.in`
- `portal.iitb.ac.in`
- `mulyankan.cse.iitb.ac.in`
- `webmail.iitb.ac.in` (see [[../bugs/webmail-split-dns-2026-09-12]])

These names resolve into `10.0.0.0/8` through campus DNS, so their resulting
traffic follows the more-specific physical-WAN campus route rather than WARP.
For Hostel 01, the authoritative campus resolver is `10.200.1.11`.

## Portal and SSO pin

`configure_dns.sh` also installs local dnsmasq `address=` records for the two
captive-portal hostnames:

- `internet.iitb.ac.in` → `10.201.250.201`
- `sso.iitb.ac.in` → `10.200.1.100`

These answers win even when campus DNS is down, so portal login can still start.
`login.sh` mirrors the same IPs with curl `--resolve` as a second layer. See
[[../bugs/campus-dns-outage-2026-08-19]].

## IPv6 behavior

AAAA filtering is disabled. dnscrypt-proxy2 is configured with
`block_ipv6 = false`, allowing dual-stack clients to resolve public IPv6 names.
DNS exposure to the LAN is through the router, not direct client policy.
Clients that manually select a public resolver bypass split-horizon IITB names;
use router-provided DNS for campus-only hosts.

## Repair and inspection

`configure_dns.sh` writes and commits UCI state, adjusts dnscrypt-proxy2, and
restarts affected services. `ensure_network.sh` verifies strict ordering,
`noresolv`, every expected upstream, campus forwarding, portal/SSO `address=`
pins, dnscrypt listen on `127.0.0.1:5453`, and IPv6 allowance. `dns_flow.sh`
prints policy (including pins) and executes representative lookups.

DNS choice and packet routing are related but separate: a private campus answer
is sent direct because of `10.0.0.0/8`. Public answers inside IITB's routed
`103.21.124.0/22` also go direct, covering browser and OS DNS caches that still
hold a public split-horizon answer. Other public answers use WARP.

## Blinkit IPv4-only exception

The exact API names `api3.blinkit.com`, `jumbo.blinkit.com` and
`api2.grofers.com` use refreshed
IPv4 hosts plus exact local DNS zones. AAAA replies are NOERROR/NODATA while
other domains retain IPv6. `refresh_blinkit_dns.sh` queries upstream directly,
installs WAN routes first, and publishes only changed records. See
[[../bugs/blinkit-ipv6-vpn-warning-2026-09-19]] for verification and limitations.
The deployed dnsmasq 2.85 does not implement the `filter_aaaa` UCI option.

## Sources

- `../../../configure_dns.sh`
- `../../../ensure_network.sh`
- `../../../dns_flow.sh`
- [[flows/traffic-routing]]
- [[campus-wan]]

- `../../../refresh_blinkit_dns.sh`

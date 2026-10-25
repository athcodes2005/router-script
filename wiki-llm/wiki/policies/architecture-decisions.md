# Architecture decisions

## Full tunnel with a campus-prefix exception

Public IPv4 and IPv6 use WARP. Campus-private IPv4 uses the physical WAN. This
is simpler and more stable than maintaining changing destination-IP lists for
games or individual websites.

## Campus domains use campus DNS

Selected IITB domains are resolved by campus DNS, producing private addresses
that naturally select the campus route. DNS policy does not install routes.

## WARP transport always bypasses WARP

Known defaults plus the endpoint stored in active config receive direct host
routes through the physical gateway. This prevents recursive tunnel failure when
Cloudflare rotates the registration endpoint.

## Repair state independently of process state

A running WARP process is not proof that routing, firewall, NAT, or LAN IPv6 is
correct. `tunnel.sh` reapplies these elements when safely reusing a live TUN.

## Prefer degraded connectivity to a dead default

After resource pressure or failed WARP recovery, the router stops WARP and uses
direct IPv4 during a bounded cooldown. The system does not leave traffic pointed
at a nonfunctional interface.

## Keep recovery and storage bounded

Network probes, registration calls, handshakes, process termination, retries,
logs, and diagnostic retention all have explicit bounds. Continuous packet
capture is outside routine automation.

## Historical policy

`../raw/sources/historical-split-routing-plan-2026-07-31.md` proposed
selected-client and blocklist-driven routing. It is marked superseded. Legacy
files remain solely for rollback compatibility.

## Sources

- `../../../tunnel.sh`
- `../../../ensure_network.sh`
- `../../../configure_dns.sh`
- `../../raw/sources/historical-split-routing-plan-2026-07-31.md`
- [[architecture]]

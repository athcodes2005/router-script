# Project overview

This project turns an OpenWrt travel router into a resilient campus gateway.
It authenticates the physical WAN, starts a Cloudflare WARP MASQUE tunnel,
routes public IPv4 and IPv6 through WARP, and keeps IIT Bombay private traffic
on the campus WAN.

## Platform

- Router: GL.iNet GL-MT3000 running OpenWrt.
- LAN gateway: `192.168.8.1/24` on `br-lan`.
- Physical WAN: `eth0`, managed as UCI interface `wan`.
- WARP interface: `tun0`, created by the bundled `usque-rs` binary.
- Runtime script directory: `/root/router-script` on the router.
- Development directory: the parent of this `wiki-llm` directory.

## Desired behavior

- Public IPv4 uses the WARP default route.
- Public IPv6 uses the WARP default route.
- Campus-private IPv4 (`10.0.0.0/8` by default) bypasses WARP.
- Campus DNS resolves selected IITB domains through `10.200.1.11`.
- Portal and SSO hostnames are also pinned locally so captive-portal login
  still works when campus DNS is down.
- LAN clients receive working IPv6 through router advertisements and DHCPv6.
- Failures fall back to usable direct IPv4 instead of leaving a dead tunnel.

## Control model

The project is intentionally script-driven. Cron runs the health pipeline each
minute, while boot schedules initialization in dependency order. The scripts
repair configuration drift and collect bounded diagnostics on failure.

The Rust program handles only WARP registration, TUN creation, MASQUE transport,
packet framing, and ICMP translation. OpenWrt shell scripts own routing, NAT,
DNS, authentication, lifecycle, and operational recovery.

## Boundaries

`blocked_sites.txt` and `warp_clients.txt` belong to an older split-routing
design. They remain for rollback compatibility but do not drive the active
full-tunnel architecture. See [[policies/architecture-decisions]].

## Sources

- `../../README.md`
- `../../PROJECT_CONTEXT.md`
- `../../tunnel.sh`
- `../../install_cron_pipeline.sh`

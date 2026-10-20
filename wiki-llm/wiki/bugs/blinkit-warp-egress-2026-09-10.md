# Blinkit WARP egress failure — 2026-09-10

Blinkit worked on the phone's mobile-data connection but failed or behaved
incorrectly over the router Wi-Fi path. The router was intentionally sending
public IPv4 and IPv6 traffic through WARP, so the app inherited a shared WARP
egress identity.

## Evidence

- The affected iPhone was identified from the router's DHCP lease table; no Mac
  network settings were changed.
- Route lookups for the phone's resolved YouTube and Blinkit addresses selected
  `tun0` before the repair.
- A bounded LAN capture recorded fresh TLS SNI names `api3.blinkit.com` and
  `jumbo.blinkit.com`; Sentry telemetry used `o1069899.ingest.us.sentry.io`.
- The same endpoints completed HTTPS from the router's physical WAN after the
  route change. Root-path responses were normal `404`/`403`, proving transport
  and TLS reached the services.

## Root cause

This was an egress-policy compatibility problem, not a Wi-Fi radio failure or
an iPhone fault. Blinkit's Cloudflare/CDN path can reject or degrade shared
WARP/proxy addresses. The old policy had no public-service exception, so all
of these connections followed the WARP default.

## Initial repair

- Added a separate `DIRECT_PUBLIC_DOMAINS` policy for the three observed Blinkit
  endpoints; it is deliberately independent of campus routing.
- `tunnel.sh` resolves those names and installs refreshed IPv4 `/32` routes via
  the campus WAN. `ensure_network.sh` refreshes the routes independently of tunnel liveness.
- `stop_tunnel.sh` removes the dynamic routes during rollback or fallback.
- No Mac, iPhone, DNS setting, or WARP process configuration was changed.

The initial repair left IPv6 on WARP because the campus WAN has no equivalent
native global IPv6 route. On 2026-09-19 the user reported an explicit VPN warning;
[[blinkit-ipv6-vpn-warning-2026-09-19]] closes that gap with refreshed IPv4-only
DNS for the observed API names, including the subsequently captured
legacy `api2.grofers.com` endpoint. The old IPv4-only bypass was incomplete for clients
that selected IPv6.

## Sources

- Bounded router packet captures and route checks performed 2026-09-10.
- `../../../tunnel.sh`
- `../../../ensure_network.sh`
- `../../../stop_tunnel.sh`

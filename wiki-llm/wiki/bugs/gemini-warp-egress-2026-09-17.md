# Gemini unusual-traffic warning — 2026-09-17

Google Gemini showed an unusual-traffic page with separate IPv4 and IPv6
addresses. The router was using WARP as the public default for both families.

## Evidence

- Router IPv4 and IPv6 defaults both selected `tun0`; the physical WAN had only
  a link-local IPv6 address, so there was no native campus IPv6 leak.
- The displayed IPv6 address was a WARP exit address, not the campus WAN.
- Gemini returned HTTP `200` from both WARP and direct tests, so the warning was
  an egress-reputation/dual-stack anti-abuse response rather than DNS failure.

## Repair

- Added `gemini.google.com` to `DIRECT_PUBLIC_DOMAINS`.
- The existing dynamic route refresher now installs the current Gemini IPv4
  addresses through the campus WAN and removes stale entries safely.
- Verified the active Gemini address selects `eth0`, returns HTTP `200`, and the
  full health pipeline passes.

IPv6 remains WARP for general traffic. Gemini clients should reload the page so
new connections use the direct IPv4 route; no Mac network settings were changed.

## Sources

- Live router route, DNS, and HTTP tests on 2026-09-17.
- `../../../tunnel.sh`
- `../../../ensure_network.sh`

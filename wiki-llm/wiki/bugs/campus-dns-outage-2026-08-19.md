# Campus DNS outage blocked captive portal — 2026-08-19

Room WAN lost public egress when campus DNS failed. The captive-portal login
path could not resolve portal/SSO hostnames, so authentication never ran and
IITB never granted room forwarding.

## Evidence

- Campus resolver `10.200.1.11` timed out campus-wide; public resolvers still
  answered ordinary names when egress existed.
- `internet.iitb.ac.in` and `sso.iitb.ac.in` failed to resolve on the router,
  so `login.sh` curl requests never reached the OAuth chain.
- Direct probes with pinned addresses succeeded: portal at `10.201.250.201`
  and SSO at `10.200.1.100` (nginx virtual hosts; different IPs).
- Corridor path used a healthy core hop (`10.250.201.2`) while the room path
  hit a dead core hop (`10.250.1.1`). MAC/IP spoofing was not viable because
  return traffic would not come back to the room port.
- Temporary `/etc/hosts` pins restored login immediately and public internet
  returned; WARP then came back on `tun0`.

## Root cause

This was an external campus DNS outage combined with a local single point of
failure in the portal login path. `configure_dns.sh` forwarded campus domains
to `10.200.1.11`, and `login.sh` depended on that resolution. When the campus
resolver died, token login could not start even though the portal and SSO
servers remained reachable on the internal campus network.

## Permanent repair

- Pin portal/SSO answers in dnsmasq with local `address=` records so LAN and
  router lookups succeed without campus DNS:
  `internet.iitb.ac.in` → `10.201.250.201`, `sso.iitb.ac.in` → `10.200.1.100`.
- Add curl `--resolve` fallbacks in `login.sh` (`PORTAL_IP` / `SSO_IP`) so
  login still works if dnsmasq is restarting or briefly unavailable.
- Keep campus-domain `server=/domain/10.200.1.11` forwarding for other IITB
  names; pinned address records override only the two portal hostnames.
- Leave temporary `/etc/hosts` pins removed after dnsmasq owns the answers.
- Preserve the earlier dnscrypt-proxy bind fix: listen on `127.0.0.1:5453` and
  restore `server_names` from backup when a truncated config would crash it.

## Verification

- After deploy, dnsmasq returned the pinned portal/SSO IPs with no `/etc/hosts`
  entries present.
- `login.sh` reported internet active and exited `0`.
- Public DNS via the router chain resolved `google.com` (A and AAAA).
- WARP remained up with healthy public probes after recovery.

## Related pages

See [[../systems/dns]], [[../systems/campus-wan]],
[[../operations/health-recovery]], and [[bgmi-portal-stale-session-2026-08-11]].

## Sources

- Live room/corridor traceroute, DNS, curl `--resolve`, and portal login tests
  on 2026-08-19.
- `../../../configure_dns.sh`
- `../../../login.sh`
- `../../../ensure_network.sh`

# Moodle and ASC campus-routing failure — 2026-08-14

IITB Moodle and ASC Portal were inaccessible from LAN clients while ordinary
public Internet and WARP health checks remained healthy.

## Evidence

- Both hostnames timed out after four seconds through the WARP default route.
- The same public addresses responded through the IITB WAN in about `66–71 ms`.
- Campus DNS returned private `10.x` split-horizon answers, while the router's
  ordinary resolver returned public IITB addresses.
- The active campus DNS policy covered the access portal, SSO, and Computer
  Centre, but omitted `moodle.iitb.ac.in` and `portal.iitb.ac.in`.
- The direct public exception covered one Computer Centre address rather than
  the IITB public prefix containing Moodle and ASC.

## Root cause

This was a policy-coverage gap, not an IITB outage or WARP failure. Clients
received public answers for the two sites, selected the WARP default, and the
sites did not complete HTTPS from the external WARP source. The direct campus
path worked immediately.

Split-horizon DNS alone was insufficient as a complete repair because browsers
and clients could retain previously cached public answers.

## Permanent repair

- Add Moodle and ASC Portal to `CAMPUS_DOMAINS`, forwarding their DNS queries to
  IITB DNS so clients normally receive private `10.x` answers.
- Add both names to `CAMPUS_DIRECT_DOMAINS` for explicit startup route checks.
- Route IITB's public `103.21.124.0/22` directly through the campus WAN. This
  also handles cached public answers without modifying client routes or DNS.
- Preserve public IPv4 and IPv6 WARP defaults for all non-campus traffic.
- Apply DNS and route state live without restarting WARP or Wi-Fi.

## Verification

- Router DNS returned the private campus addresses for both names.
- Moodle returned its expected HTTP `303` login redirect in about `70 ms`.
- ASC Portal returned HTTP `200` in about `63 ms`.
- A Wi-Fi client with cached public answers reached the exact sites in about
  `34–38 ms`, proving the public-prefix route covers stale DNS caches.
- WARP process and readiness PIDs remained unchanged and matching.
- Public WARP IPv4 and IPv6 probes returned HTTP `204`, and subsequent health
  runs continued to pass.
- Shell syntax and ShellCheck passed, and deployment hashes matched.
  Timestamped rollback copies remained on the router until 2026-10-22, when they
  were archived off it ([[../log]]). No Mac configuration was changed.

## Related pages

See [[../systems/dns]], [[../systems/campus-wan]], and
[[../flows/traffic-routing]].

## Sources

- Live split-DNS, route, HTTPS, WARP, and Wi-Fi-client tests on 2026-08-14.
- `../../../configure_dns.sh`
- `../../../tunnel.sh`
- `../../../ensure_network.sh`
- `../../../stop_tunnel.sh`

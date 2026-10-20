# Webmail split-DNS omission — 2026-09-12

IITB webmail failed over Wi-Fi while other Internet paths remained available.

## Evidence

- Router DNS returned the public address for `webmail.iitb.ac.in`.
- IITB campus DNS returned the internal address `10.200.1.29`.
- The public address returned an IITB Squid `503 ERR_CONNECT_FAIL`.
- HTTPS to the campus address returned `200` in about 32 ms over the campus
  WAN, proving the service and campus path were healthy.

## Root cause

`webmail.iitb.ac.in` was missing from the router's campus split-DNS and direct
hostname policies. Clients therefore used the public answer, even though the
site is intended to be reached through IITB's internal service address.

## Repair

- Added `webmail.iitb.ac.in` to `CAMPUS_DOMAINS`, forwarding it to IITB DNS.
- Added it to `CAMPUS_DIRECT_DOMAINS` so startup and health checks preserve the
  campus route even when clients retain a cached public answer.
- Applied dnsmasq live and verified router DNS now returns `10.200.1.29`.
- Verified HTTPS returns `200`; the normal health pipeline also passed.
- No Mac or phone network settings were modified.

## Sources

- Live router DNS, route, HTTP/HTTPS, and health checks on 2026-09-12.
- `../../../configure_dns.sh`
- `../../../tunnel.sh`
- `../../../ensure_network.sh`

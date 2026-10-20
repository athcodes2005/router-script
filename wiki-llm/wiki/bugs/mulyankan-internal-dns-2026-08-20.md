# Mulyankan internal-DNS access failure — 2026-08-20

An IITB Mulyankan password-reset page could not open from a LAN client despite
healthy public Internet, WARP, and campus connectivity.

## Evidence

- IITB DNS resolved `mulyankan.cse.iitb.ac.in` to a private `10.x` address.
- Public DNS returned no usable answer for the internal-only hostname.
- The router had no campus DNS forwarding entry for the host, so normal clients
  could not resolve it.
- The service itself was healthy: direct private HTTPS returned its expected
  redirect in about `69 ms`.
- The affected Mac had manually configured Google DNS, bypassing the router's
  campus split-DNS policy. Its default gateway was still the router.

## Repair

- Added `mulyankan.cse.iitb.ac.in` to `CAMPUS_DOMAINS` and
  `CAMPUS_DIRECT_DOMAINS`.
- Applied only the DNS configuration live; WARP and Wi-Fi were not restarted.
- The user restored the Mac's DNS setting to automatic/router-provided DNS.
- No password-reset URL, token, email address, or account data was retained.

## Verification

- Router DNS returned the private IITB address and the route selected `eth0`.
- The service returned its expected HTTP redirect in about `78 ms` from the
  router and `43 ms` from the Wi-Fi client.
- WARP process/readiness PIDs remained unchanged and the health pipeline kept
  passing.
- Shell syntax and ShellCheck passed; timestamped rollback copies remain on the
  router.

## Sources

- Live sanitized DNS, route, and HTTPS tests on 2026-08-20.
- `../../../configure_dns.sh`
- `../../../ensure_network.sh`
- `../../../tunnel.sh`

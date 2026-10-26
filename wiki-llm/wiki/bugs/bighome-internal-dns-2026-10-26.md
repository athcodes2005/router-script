# BigHome internal-DNS access failure — 2026-10-26

`https://bighome.iitb.ac.in` did not load from LAN clients, with the public
Internet, WARP and campus routing all healthy. Same failure class as
[[mulyankan-internal-dns-2026-08-20]].

## Evidence

- Public DNS (Cloudflare DoH) returned NXDOMAIN: the name is internal-only.
- Campus DNS (`10.200.1.11`), queried from the router, returned a private
  10.200.x campus address.
- The router's dnsmasq returned NXDOMAIN. The name was not in `CAMPUS_DOMAINS`,
  so it went to the dnsproxy/public upstreams, and with `strictorder` campus DNS
  was never asked.
- Routing was already correct: `CAMPUS_NETS` covers `10.0.0.0/8`, the route
  goes via `eth0`, and HTTPS answered a redirect (302) in about 46 ms over `eth0`.

## Repair

- Appended `bighome.iitb.ac.in` to the `CAMPUS_DOMAINS` default in
  `defaults.sh`, so `configure_dns.sh` forwards it to campus DNS and
  `ensure_network.sh` treats a missing entry as DNS drift.
- Deliberately not added to `CAMPUS_DIRECT_DOMAINS`: its address lies inside
  `CAMPUS_NETS`, so no host route is needed.
- Tests: `tests/test_bighome_dns.py`, plus the updated defaults and sandbox
  stub.

## Verification

Pending deploy. After deploy, confirm the router resolves the name to a private
10.200.x address and that a LAN client loads the page (clients must use
router-provided DNS).

## Sources

- `../../../defaults.sh`
- `../../../configure_dns.sh`
- `../../../ensure_network.sh`
- `../../../tests/test_bighome_dns.py`
- Live sanitized DNS, route and HTTPS tests on 2026-10-26.

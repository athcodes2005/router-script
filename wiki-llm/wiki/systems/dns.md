# DNS system

dnsmasq on the router is the LAN resolver and forwarding policy point. Its
configuration is deterministic: `noresolv=1` prevents dynamically supplied WAN
resolvers from silently bypassing the configured chain.

## Upstream policy

The expected server list places encrypted DNS (`127.0.0.1#5453`) first, followed
by Google IPv4 resolvers (`8.8.8.8`, `8.8.4.4`) and the IITB campus DNS server
(`10.200.1.11`) as fallbacks. dnsmasq uses strict ordering (`strictorder=1`).

On GL.iNet 4.11.0, `configure_dns.sh` configures `/usr/sbin/dnsproxy`
(`/etc/dnsproxy/dnsproxy.yaml`) on `127.0.0.1:5453` with dnsproxy's default
upstream mode (the YAML sets no `upstream-mode`), using this upstream list:
Cloudflare DoT/DoH (`tls://1.1.1.1:853`, `tls://1.0.0.1:853`,
`https://cloudflare-dns.com/dns-query`) and Quad9 DoT/DoH (`tls://9.9.9.9:853`,
`https://dns.quad9.net/dns-query`). Parallel mode is deliberately not set: the
router's dnsproxy version is unverified and an unknown key could stop the
daemon and cut DNS. An earlier note of a ~20 ms warm lookup was measured, not
configured, and does not imply parallel mode.

Selected campus names are explicitly forwarded to campus DNS:

- `internet.iitb.ac.in`
- `sso.iitb.ac.in`
- `cc.iitb.ac.in`
- `moodle.iitb.ac.in`
- `portal.iitb.ac.in`
- `mulyankan.cse.iitb.ac.in`
- `webmail.iitb.ac.in` (see [[../bugs/webmail-split-dns-2026-09-12]])
- `bighome.iitb.ac.in` (see [[../bugs/bighome-internal-dns-2026-10-26]]; not a direct-route
  domain, since its address is already inside `CAMPUS_NETS`)

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

AAAA filtering is disabled. `dnsproxy` (which replaced `dnscrypt-proxy2` on
firmware 4.11.0+) forwards both A and AAAA queries without IPv6 blocking,
allowing dual-stack clients to resolve public IPv6 names.
DNS exposure to the LAN is through the router, not direct client policy.
Clients that manually select a public resolver bypass split-horizon IITB names;
use router-provided DNS for campus-only hosts.

## Repair and inspection

`configure_dns.sh` writes and commits UCI state, configures `/etc/dnsproxy/dnsproxy.yaml`
(`dnsproxy` replaced `dnscrypt-proxy2` on firmware 4.11.0+; the legacy
`dnscrypt-proxy` TOML code is commented out in the scripts), and restarts
`dnsproxy` and `dnsmasq`. A failed `dnsproxy` restart is logged as a warning
and the script carries on, so the dnsmasq, pin and ipset repair still runs
(dnsmasq falls back to the plain resolvers). Each `ensure_network.sh` tick restarts `dnsproxy` if its process is not running
(`dnsproxy_alive_repair`: needs `/etc/init.d/dnsproxy` and a `dnsproxy.yaml`
mentioning `5453`; once per tick, logged, a failed restart only warns).
`check_platform_once` still warns once per boot if `dnsproxy` is not running.
`ensure_network.sh` verifies `strictorder` and
`noresolv`, that the four upstreams (`127.0.0.1#5453`, `8.8.8.8`, `8.8.4.4`,
`10.200.1.11`) come first and in order, forwards for
exactly the listed campus hosts (a whole-zone `/iitb.ac.in/` forward counts as
drift), portal/SSO `address=` pins, and `/etc/dnsproxy/dnsproxy.yaml` (port
`5453` and `tls://1.1.1.1:853`). `dns_flow.sh`
prints policy (including pins and `dnsproxy.yaml`) and executes representative
lookups.

DNS choice and packet routing are related but separate: a private campus answer
is sent direct because of `10.0.0.0/8`. Public answers inside IITB's routed
`103.21.124.0/22` also go direct, covering browser and OS DNS caches that still
hold a public split-horizon answer. Other public answers use WARP.

## Blinkit IPv4-only exception

The exact API names `api3.blinkit.com`, `jumbo.blinkit.com` and
`api2.grofers.com` use refreshed
IPv4 hosts plus exact local DNS zones. AAAA replies are NOERROR/NODATA while
other domains retain IPv6. `refresh_blinkit_dns.sh` queries upstream directly,
installs WAN routes first, publishes only changed records, and signals dnsmasq
via `/var/run/dnsmasq/dnsmasq*.pid` (audit F50). See
[[../bugs/blinkit-ipv6-vpn-warning-2026-09-19]] for verification and limitations.
The vendor dnsmasq (2.85 before, 2.92 on 4.11.0) init script ignores the
`filter_aaaa` UCI option, so it stays 0 in every mode; game mode no longer
toggles it.

## Sources

- `../../../configure_dns.sh`
- `../../../ensure_network.sh`
- `../../../dns_flow.sh`
- [[flows/traffic-routing]]
- [[campus-wan]]

- `../../../refresh_blinkit_dns.sh`

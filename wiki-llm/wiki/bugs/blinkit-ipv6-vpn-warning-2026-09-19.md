# Blinkit VPN warning: IPv6 and missing legacy API — 2026-09-19

The iPhone displayed “You're using VPN” in Blinkit on router Wi-Fi. The user
confirmed no phone VPN and that the warning occurs only on Wi-Fi, not mobile
data. WARP on the router still affects devices without their own VPN client.

## Findings and failed first attempt

The original bypass covered IPv4 for `api3.blinkit.com` and
`jumbo.blinkit.com`, while their IPv6 addresses still used WARP. IPv4-only DNS
was deployed for those names, but the user explicitly reported continued
failure. That change closed a real gap without resolving the app failure.

A later bounded capture of the affected iPhone's traffic observed a TLS
ClientHello for **`api2.grofers.com`** as well as the two known Blinkit API names.
The legacy API's captured IPv4 destination selected `tun0`; it was missing from
both the direct-route and scoped DNS policy. This is a confirmed missing route,
not proof that all service-side rejection is solved. Root-path requests returned
HTTP 403 on both WAN and WARP; unauthenticated requests are not an app test.

## Current deployed policy

- All three observed API names are included in `BLINKIT_IPV4_DOMAINS` and
  `DIRECT_PUBLIC_DOMAINS` defaults across configuration, startup and health.
- `refresh_blinkit_dns.sh` queries upstream resolvers independently of local
  DNS, installs direct WAN routes, then publishes IPv4-only records under
  `/etc/router-script/blinkit-hosts/hosts`.
- dnsmasq includes that directory and treats the three exact API zones as local.
  Their AAAA replies are NOERROR/NODATA; unrelated services retain IPv6.
- Saved records survive reboot and upstream DNS failures. Failed route
  installation prevents publishing a new record set. Changed hosts trigger HUP,
  which also clears dnsmasq's cache; since 2026-10-22 each change logs one
  timestamped line with the number of dnsmasq PIDs signalled.
- Deployed up to 2026-10-22: the refresher never deletes routes, and only the
  healthy-tick public refresher removes a replaced address's route. A set
  replaced during WARP fallback or game mode therefore kept its routes. On
  2026-10-22 the router held 20 such CloudFront routes from earlier
  `api3.blinkit.com` answers.
- Commit `775bcd4` (not yet deployed) makes the refresher remove the dropped
  addresses' routes after publishing a new set, unless another refresher still
  lists them. It also resolves every name before installing any route.
- The installed dnsmasq 2.85 rejects `--filter-AAAA`, and its init script ignores
  `filter_aaaa`; setting that UCI flag alone does not implement filtering.

The policy covers observed names, not every possible future Blinkit dependency.
Clients using independent encrypted DNS can bypass it. Persisted answers can
become stale during prolonged upstream DNS outages. Broader campus-egress
reputation remains a possible cause if a correlated direct-path app retry fails.

## Verification and status

The initial DNS mechanism was verified on an isolated loopback listener before
application. After adding the observed legacy API, fourteen regression tests
passed, including policy consistency and actual record generation for that name.
Live checks confirmed IPv4 WAN routes and AAAA NODATA for all three names.
WARP retained the same process throughout; Wi-Fi was not restarted. DNS restarted
once per policy deployment. The phone was asked to refresh Wi-Fi and retry.
**App-level success remains pending user confirmation after the legacy-API fix.**

Backups: `/root/router-script/blinkit-backup-20260919/` for the first change and
`/root/router-script/blinkit-backup-20260919-followup/` for the legacy-API change.
Only relevant hostname/route findings are retained in documentation; bounded
captures are removed after inspection.

## Related pages

See [[blinkit-warp-egress-2026-09-10]], [[../systems/dns]],
[[../operations/health-recovery]], and [[game-latency-audit-2026-09-19]].

## Sources

- User screenshot, Wi-Fi-only failure report and live checks on 2026-09-19.
- Bounded iPhone TLS/DNS metadata capture on 2026-09-19; no TLS decryption.
- `../../../refresh_blinkit_dns.sh`, `../../../configure_dns.sh`
- `../../../ensure_network.sh`, `../../../tunnel.sh`
- `../../../tests/test_blinkit_dns.py`
- [dnsmasq manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html).

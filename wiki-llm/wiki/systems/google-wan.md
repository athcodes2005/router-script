# Google services through IITB WAN

## Active policy

Deployed and verified on 2026-09-23 at the user's request after YouTube's bot
challenge. Google service IPv4 destinations use IITB WAN instead of WARP.
This changes the egress identity; it cannot guarantee Google will trust a shared
campus public IP. User-visible disappearance of warnings is not yet confirmed.

- `google_service_ranges.txt` contains 402 service prefixes from Google's
  published `goog.json` minus `cloud.json`, generated from the September 22 feed.
  Excluding Cloud customer ranges avoids a blanket bypass of Google Cloud.
- `google_domains.txt` adds suffix-based DNS learning for Google, YouTube,
  Googlevideo, Gmail, Google APIs, assets, and listed regional domains.
- dnsmasq adds A/AAAA answers to `google_dns4`/`google_dns6` with a one-day expiry.
  Static prefixes cover known service addresses even with cached or private DNS.
- IPv4 static/learned matches get mark `0x100000/0x100000`; rule 710 selects
  table 102 with a direct WAN default plus LAN/WAN connected routes.
- Existing game policy uses separate mark bits and table 101.
- Rule 690 preserves explicit router sockets bound to `tun0`, including WARP
  health probes. Ordinary router and LAN Google traffic follows the bypass.

## IPv6 and recovery

There is no usable native WAN IPv6 exit. Google IPv6 destinations are rejected
with TCP resets or ICMPv6 port-unreachable so dual-stack applications use IPv4.
Other IPv6 destinations retain WARP. IPv6-only Google clients cannot connect.

`google_wan_policy.sh` creates destination sets, atomically swaps updated static
sets, and installs only missing rules. Tunnel startup and every health run invoke
it. DNS configuration creates sets before dnsmasq starts and retains other sets.
Policy failure is logged separately rather than restarting a working WARP tunnel.
A firewall restart or flush removes the marks and rejects. The fw3 include
`firewall_hook.sh` starts a health check about two seconds later, which restores
them; before, the gap lasted until the next 30-second run.

## Maintenance and limitations

Run `python3 tools/update_google_ranges.py` locally to refresh the official range
snapshot; deploy the resulting file and invoke the policy helper. The script sync
manifest includes the helper and both data files. DNS learning is automatic;
refreshing the published static snapshot is manual. New addresses resolved via
private DNS outside that snapshot may remain on WARP until the snapshot updates.
IP-based policy also affects services sharing a matched destination address.

Close and reopen affected apps after a routing change: existing TCP/QUIC sessions
can retain their old source/NAT state. No router-wide connection flush was used.

## Verification and rollback

- Nineteen regression tests passed, including the missing `LAN_SUBNET` default
  exposed in existing game policy repair.
- Live routes for Google, YouTube, Gmail, Drive, APIs and thumbnails select WAN.
- Normal and explicitly tunnel-bound Google IPv4 probes both returned HTTP 204;
  unrelated Cloudflare IPv6 returned 204. Google IPv6 rejected in about 4 ms.
- LAN match counters increased, repeat installs did not duplicate policy rules,
  complete health check passed, and WARP PID remained unchanged.
- Router backup: `/root/router-script/google-backup-20260923/`, removed on
  2026-10-22. Its scripts are in git history; its DHCP config and first-deploy
  copies are in the off-router archive ([[../log]]). Restore original
  scripts and DHCP configuration, remove the helper's exact firewall rules,
  rules 690/710 and table 102, then restart dnsmasq. Restore health scripts before
  removing policy so the next health run does not recreate it. See deployment
  helper for exact rollback rule specifications; preserve unrelated policy.

## Sources

- `../../../google_wan_policy.sh`, `../../../google_domains.txt`
- `../../../google_service_ranges.txt`, `../../../tools/update_google_ranges.py`
- `../../../ensure_network.sh`, `../../../configure_dns.sh`, `../../../tunnel.sh`
- `../../../tests/test_google_ranges.py`, `../../../tests/test_network_recovery.py`
- `../../../audit/2026-09-23-google/deploy.py`
- [Google documented service-range subtraction](https://docs.cloud.google.com/vpc/docs/configure-private-google-access)
- Live router checks on 2026-09-23; user request and YouTube screenshot.

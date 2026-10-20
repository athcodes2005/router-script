# Blinkit follow-up — 19 September 2026

User confirms the warning occurs only on Wi-Fi. A bounded iPhone-only capture
observed TLS SNI api2.grofers.com, api3.blinkit.com and jumbo.blinkit.com.
The legacy Grofers API destination selected tun0 before this change.

Added api2.grofers.com to all relevant DNS and direct-route defaults and
verified A records route through eth0 and AAAA replies are NOERROR/NODATA.
Fourteen regression tests passed. WARP process remained unchanged.

The unauthenticated legacy API root returned HTTP 403 via both direct WAN and
WARP, so these requests do not establish app acceptance. Phone-side retry was
requested; success must not be inferred from router tests.

Router rollback files: /root/router-script/blinkit-backup-20260919-followup/.
No device-wide direct routing test was applied after discovering the missing
endpoint. Packet captures are deleted; only relevant findings are retained.

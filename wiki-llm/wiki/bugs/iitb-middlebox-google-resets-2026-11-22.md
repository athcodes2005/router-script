# IITB middlebox Google TLS resets and WAN-recovery teardowns — 2026-11-22

Google API streams (Antigravity `daily-cloudcode-pa.googleapis.com` and other
Google HTTPS endpoints) suffered recurring `EOF`, `connection reset by peer`,
and `SSL connection timeout` errors, while the network felt intermittently
sluggish.

## Incident evidence

- Failing client logs showed `daily-cloudcode-pa.googleapis.com` dropping almost
  every minute on the `:32`–`:33` second mark across two sessions.
- `nf_conntrack` confirmed those flows (`172.217.118.4:443`,
  `172.217.114.4:443`) were NAT'd out direct `eth0` by `google_wan_policy.sh`
  (table `102`), while LAN Google IPv6 was rejected on `br-lan`.
- Live `tcpdump` on `eth0` at `12:13:24–12:13:32 IST` proved IITB's border
  transparent TCP proxy (`TTL = 59`, behind hop 6) answered `SYN-ACK` and
  `ClientHello` `ACK` in `0.5–2 ms`, stalled TLS, and injected `FIN`/`RST` to
  active direct TCP 443 flows at `:32`.
- Side-by-side tests from the router showed direct `eth0` failing `4/5` and
  timing out for ~4 minutes straight (`11:33–11:37`, plus the `06:17` snapshot),
  while `tun0` (WARP over UDP/QUIC) passed `100%` (`5/5`, `10/10`, `20/20`) in
  `75–120 ms`.
- `ensure.log` also showed two full WARP teardowns (`06:46:04`, `11:06:05`) plus
  a double teardown (`06:47:32`) triggered by `ensure_network.sh` probing direct
  WAN three times per healthy tick, tearing down WARP on an unconfirmed second
  check, and leaving `/tmp/router-script-interactive-login-required` behind
  after post-teardown recovery.
- 5 GHz (`mt798112`) on `channel=auto` sat on channel 48 (`HE80`), overlapping
  four campus SSIDs on channel 36 (`-75 dBm`) and causing local ping spikes up
  to `35.9 ms` (`1.1.1.1` up to `92.4 ms`).

## Root cause

1. IITB's border transparent TCP proxy on `eth0` actively stalled and reset
   direct TCP 443 Google connections every minute at `:32`–`:33`, and
   `google_wan_policy.sh` forced all Google traffic onto `eth0`.
2. `ensure_network.sh` evaluated `! internet_v4_ok` before checking the
   interactive-login marker and re-ran an unconfirmed `internet_v4_ok` before
   teardown, turning transient WAN blips into full WARP teardowns.
3. `INTERNET_PROBE_URLS` probed Google before Cloudflare, stalling healthy ticks.
4. 5 GHz `channel=auto` picked an 80 MHz block shared with campus APs.

## Permanent repair

- Defaulted `GOOGLE_WAN_POLICY=0` in `defaults.sh`, removed `gemini.google.com`
  from `DIRECT_PUBLIC_DOMAINS`, and added idempotent teardown in
  `google_wan_policy.sh` (mangle marks, `ip6tables` rejects, ip rules `690`/`710`,
  table `102`, `google_*` ipsets, and dnsmasq UCI ipset entries).
- Fixed `ensure_network.sh` to check `[ -f "$INTERACTIVE_LOGIN_MARKER" ]` first,
  gate tunnel teardown on `PORTAL_RECOVERY_ATTEMPTED=1`, and remove
  `$INTERACTIVE_LOGIN_MARKER` on post-teardown recovery.
- Reordered `INTERNET_PROBE_URLS` to probe `https://cp.cloudflare.com/generate_204`
  before Google.
- Pinned `WIFI_5G_CHANNEL=149` (non-DFS UNII-3 in `IN`, zero neighboring APs) in
  `defaults.sh`, `configure_wifi.sh`, and `ensure_network.sh`.

## Verification

- `sh -n`, `dash -n`, `shellcheck`, and all 271 Python tests passed.
- Deployed via `sync_to_router.sh`: verified `0` leftover Google WAN rules,
  Google/Antigravity flows NAT'd over `tun0`, `usque-rs` unbroken across six
  subsequent `:32`–`:33` WAN blips, and local ping improved from `7.21 ms avg /
  35.93 ms max` to `3.36 ms avg / 5.44 ms max`.

## Sources

- `../../../defaults.sh`, `../../../google_wan_policy.sh`, `../../../ensure_network.sh`, `../../../configure_wifi.sh`
- `../../../tests/test_defaults.py`, `../../../tests/test_google_policy.py`, `../../../tests/test_pipeline.py`, `../../../tests/test_tunnel_start.py`
- [[../systems/google-wan]], [[../systems/wifi]], [[../operations/health-recovery]]

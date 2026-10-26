# Incident: `/tmp` exhaustion and sluggish Wi-Fi

## Symptom

Wi-Fi internet became very sluggish after network/game diagnostics. WARP had
also previously entered frequent recovery cycles, making the connection appear
intermittent even when the physical WAN was usable.

## Verified cause

Two stale `tcpdump` processes continued writing separate packet captures under
router `/tmp`. Each file grew to roughly 119 MB, together filling the roughly
240 MB RAM-backed filesystem. The capture processes and their exact output files
were removed after local diagnostic copies had already been retained.

The WARP client lacked retry backoff, so failures could immediately loop. The
minute health check also retried WARP every run, leaving dead tunnel defaults
during repeated failures. These behaviors amplified a storage-pressure event.

## Corrections

- Health diagnostics now display `/tmp` usage, largest entries, and tcpdump.
- WARP is stopped at a configurable `/tmp` threshold, restoring direct IPv4.
- Failed restart enters a five-minute cooldown instead of minute-by-minute churn.
- The Rust client uses bounded handshake phases and exponential reconnect delay.
- Diagnostics have collision-proof names and bounded retention.
- Log rotation runs every six hours.
- Tunnel status output is kept off persistent flash.

## Prevention

Manual packet captures must always be bounded by file size, packet count, or a
supervised timeout. Their processes and output must be cleaned together. Normal
diagnostics use snapshots and do not start packet capture.

## Sources

- Live router process, filesystem, and `/tmp` inspection on 2026-08-01.
- `../../../ensure_network.sh`
- `../../../diagnose.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/src/tunnel.rs`
- [[operations/diagnostics]]

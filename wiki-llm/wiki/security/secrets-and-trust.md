# Secrets and trust boundaries

## Secret files

`.env` contains IITB credentials and optional operational settings.
`config.json` contains WARP private-key and access-token material. Both files
must be mode `0600` locally and on the router. Their values must never appear in
the wiki, logs, diagnostics, command output, or support transcripts.

WARP rotation keeps a temporary `config.json.previous`, also mode `0600`, only
until the new identity is verified or rollback completes.

OpenWrt wireless configuration and its rollback snapshot contain Wi-Fi key
material. Both remain router-local at mode `0600`; the wiki records paths only.

## Deployment protection

Synchronization uses a private staging directory and applies final permissions
after promotion. Failed sync cleanup removes the exact staging directory and
restores a previously running tunnel. It does not expose secret files through a
partially installed set.

## Portal credentials

`login.sh` validates required variables and uses `--location-trusted` for the
campus headless-token redirect flow. Basic Auth credentials can therefore be
forwarded across origins in that HTTPS redirect chain; HTTPS-only redirects
and a five-redirect limit are enforced, but there is no hostname allowlist.
This is an explicit trust dependency on the campus portal, not same-origin-only
authentication. Query strings and response bodies are excluded from login logs.
The credentials reach curl on stdin as a config line (`-K -`), never in its
command line, which any local process could read from `/proc`.

## WARP endpoint trust

The client constructs its enrollment certificate locally. QUIC library CA
verification is disabled for this special endpoint flow, but the peer certificate
is mandatory and its SPKI must match the public key delivered by registration.
A missing certificate or mismatched key terminates the session.

## Router services and the tunnel

SSH, the GL.iNet admin UI (80, 443, 8080, 8443) and dnsmasq listen on all
addresses. fw3 filters input only from `br-lan` and `eth0`. WAN input admits
only DHCP renewal, IGMP and port forwards, so campus hosts cannot reach these
services, and dnsmasq is not an open resolver.

`tun0` is in no fw3 zone, and `INPUT`'s policy is `ACCEPT`. A connection
arriving over the tunnel therefore reached these services (audit F31, found on
2026-10-22). Commit `3b3a183` drops new inbound connections on `tun0` for
IPv4 and IPv6:
- `tunnel.sh` adds the rule at start.
- `ensure_network.sh` restores it after a firewall reload. It never restarts
  WARP for it.
- `stop_tunnel.sh` leaves it in place, because it is inert without `tun0`.

Replies are not NEW and still pass. The commit was deployed on 2026-10-22 at
08:39. Whether WARP ever delivers such connections is unverified: the rule's
drop counter (`iptables -L INPUT -v -n | grep tun0`) shows it.

## Diagnostic boundary

Metadata such as file modes, routes, and endpoint reachability may be recorded.
Secret file contents, cookies, tokens, private keys, and raw login bodies may not.
`diagnose.sh` redacts secret values from the wireless status (which embeds WPA
passphrases), and `collect_diagnostics.sh` writes snapshots with mode `0600`.
Packet captures are considered sensitive even when they contain no payload.

## Sources

- `../../../login.sh`
- `../../../tunnel.sh`, `../../../ensure_network.sh` (tun0 input rule)
- `../../../sync_to_router.sh`
- `../../../rotate_tunnel_ip.sh`
- `../../../usque-rs-optimized/src/config.rs`
- `../../../usque-rs-optimized/src/tls.rs`
- `../../../usque-rs-optimized/src/tunnel.rs`

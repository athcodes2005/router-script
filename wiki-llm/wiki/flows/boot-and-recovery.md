# Boot and recovery flow

## Boot sequence

`bootstrap_router.sh` is the manual one-shot setup: it configures DNS and LAN
IPv6, installs cron, and invokes the complete health pipeline. After later
reboots, persistent UCI settings return with OpenWrt and the next staggered cron
health run authenticates the WAN or starts WARP when either is missing.

## Healthy steady state

At the start and midpoint of each minute, the health pipeline attempts to acquire
its lock, validates configuration and active paths, clears any expired failure
marker after success, logs the outcome, and releases the lock. An already
running tunnel can have its routes repaired without replacing its process.

## Firewall rebuild

`fw3 restart` and `fw3 flush` remove every rule router-script added: NAT, MSS,
LAN↔`tun0` forwarding, the `tun0` input drop, the Google marks and rejects, and
the game-session chain. `fw3 reload` keeps them. After every fw3 start, restart
and reload, the fw3 include `firewall_hook.sh` starts a health check about two
seconds later if a WARP client runs, and that check restores whatever is
missing. At boot no client runs yet, so the include does nothing.

## WAN or portal failure

Missing WAN lease causes tunnel teardown followed by WAN interface cycling.
Failed direct-WAN probing invokes portal login. A token redirect to `logout.php`
while public probes fail triggers immediate stale-session logout and re-login.
If tunnel state masks recovery, the tunnel is removed and login is retried over
direct WAN.

## WARP failure

A failed tunnel validation causes one bounded stop/start attempt. The Rust client
also limits its own handshake duration, ends a session after 90 s without a
packet from the server, and backs off after failed or short-lived sessions
([[../systems/warp-client]]). `logread -e usque-rs` shows why each session
ended.

If restart validation still fails, shell control removes tunnel defaults and
leaves direct IPv4 active for a five-minute cooldown. Later health runs retry.

## Resource pressure

High `/tmp` use bypasses the restart attempt: evidence is captured, WARP is
stopped, direct IPv4 is restored, and cooldown begins. This prevents the failure
feedback loop documented in [[bugs/tmp-exhaustion-2026-08-01]].

## Sources

- `../../../install_cron_pipeline.sh`
- `../../../bootstrap_router.sh`
- `../../../ensure_network.sh`
- `../../../login.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/src/tunnel.rs`

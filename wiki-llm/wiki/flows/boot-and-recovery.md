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

## WAN or portal failure

Missing WAN lease causes tunnel teardown followed by WAN interface cycling.
Failed direct-WAN probing invokes portal login. A token redirect to `logout.php`
while public probes fail triggers immediate stale-session logout and re-login.
If tunnel state masks recovery, the tunnel is removed and login is retried over
direct WAN.

## WARP failure

A failed tunnel validation causes one bounded stop/start attempt. The Rust client
also limits its own handshake duration and exponentially backs off repeated
session errors.

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
- `../../../usque-rs-optimized/src/tunnel.rs`

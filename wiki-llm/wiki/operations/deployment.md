# Deployment and bootstrap

Use `sync_to_router.sh` from the project root to deploy. The default destination
is `root@192.168.8.1:/root/router-script`; environment overrides are supported.

## Safe synchronization

The sync process records whether the tunnel is running, then uploads the
complete deployment set into a private mode-`0700` staging directory while WARP
keeps running, with a SHA-256 manifest of every file. Staging needs no lock.

`promote_staged.sh` then runs on the router as one process (audit F40):
- it checks every staged file against the manifest and promotes nothing on a
  mismatch;
- it takes the maintenance lock through `lock.sh`, so the lock's owner is alive
  for the whole step and no health check takes it over by age; a busy lock
  ends it with status 75 after `SYNC_LOCK_WAIT` (30 s);
- it stops WARP and moves the files in manifest order, sourced helpers first;
- scripts, the executable and the rollback binary `usque-rs-upstream-v0.1.0`
  receive mode `0755`, and `.env` and `config.json` mode `0600`;
- it ends with `sync`, so a power cut right after a deploy cannot leave
  zero-length files;
- it ignores SIGHUP and SIGPIPE and does not stop on a failed write, so a
  dropped SSH connection cannot end it halfway.

On the Mac, a trap removes staging state and restarts a previously running
tunnel after failures. The deployment that introduced `lock.sh` (2026-10-23)
held the lock the old way, with an ownerless `mkdir`, because the old health
check treated `lock.sh`'s owner file as stale (report section 19.6).

The router copy of `blocked_sites.txt` may be edited independently. Sync refuses
to overwrite divergent content unless `--force` is explicitly supplied. Use
`sync_from_router.sh` to pull it first when appropriate.

`config.json` gets the same protection, because `rotate_tunnel_ip.sh` registers
new WARP identities on the router and leaves the local copy stale. Only SHA-256
hashes are compared; the file holds the private key and is never printed. A
router without a registration (first deploy) is not blocked.

## First-time bootstrap

`bootstrap_router.sh` runs, in order, `configure_wifi.sh`, `configure_dns.sh`,
`configure_lan_ipv6.sh`, `install_cron_pipeline.sh`, `install_firewall_hook.sh`
(the fw3 include, [[health-recovery]]) and one `ensure_network.sh` pass. It does not call `login.sh` or `tunnel.sh` directly; that health pass
performs portal login recovery and starts WARP when required.
`install_cron_pipeline.sh` installs the twice-per-minute health check plus six-hour log
rotation and diagnostic snapshot tasks.

## Verification checklist

- Confirm shell syntax on the router.
- Confirm secret modes are `0600`.
- Confirm dnsmasq uses `noresolv=1` and campus forwarding rules.
- Confirm IPv4 and IPv6 defaults use `tun0`.
- Confirm campus destinations use `eth0`.
- Confirm public IPv4 and IPv6 Cloudflare traces report WARP enabled.
- Confirm `/tmp` has space and no unintended capture process is running.
- Confirm `uci get firewall.router_script.path` names `firewall_hook.sh`.
- Confirm `logread -e usque-rs` shows the client's connection events.

## Sources

- `../../../sync_to_router.sh`, `../../../promote_staged.sh`, `../../../lock.sh`
- `../../../sync_from_router.sh`
- `../../../bootstrap_router.sh`
- `../../../install_cron_pipeline.sh`, `../../../install_firewall_hook.sh`

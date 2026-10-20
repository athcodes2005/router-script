# Deployment and bootstrap

Use `sync_to_router.sh` from the project root to deploy. The default destination
is `root@192.168.8.1:/root/router-script`; environment overrides are supported.

## Safe synchronization

The sync process checks whether the tunnel is running, acquires the same remote
maintenance lock used by health checks. It uploads the complete deployment set
into a private mode-`0700` staging directory while WARP remains running. Only
after successful transfer does it stop WARP for promotion.

Only after every transfer succeeds are staged files moved into the live
directory. Scripts and the executable receive mode `0755`; `.env` and
`config.json` receive mode `0600`. A trap removes staging state, releases the
lock, and restarts a previously running tunnel after failures.

The router copy of `blocked_sites.txt` may be edited independently. Sync refuses
to overwrite divergent content unless `--force` is explicitly supplied. Use
`sync_from_router.sh` to pull it first when appropriate.

## First-time bootstrap

`bootstrap_router.sh` runs, in order, `configure_wifi.sh`, `configure_dns.sh`,
`configure_lan_ipv6.sh`, `install_cron_pipeline.sh`, and one `ensure_network.sh`
pass. It does not call `login.sh` or `tunnel.sh` directly; that health pass
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

## Sources

- `../../../sync_to_router.sh`
- `../../../sync_from_router.sh`
- `../../../bootstrap_router.sh`
- `../../../install_cron_pipeline.sh`

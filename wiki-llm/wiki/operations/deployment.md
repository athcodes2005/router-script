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
- scripts and the executable receive mode `0755` (the rollback binary
  `usque-rs.prev` is router-local and never shipped), and `.env` and `config.json` mode `0600`;
- it ends with `sync`, so a power cut right after a deploy cannot leave
  zero-length files;
- it ignores SIGHUP and SIGPIPE and does not stop on a failed write, so a
  dropped SSH connection cannot end it halfway.

On the Mac, a trap removes staging state and, if the tunnel was running and is
now stopped, runs the router's `ensure_network.sh` as a gate
([[health-recovery]]). That starts the tunnel under the maintenance lock and
tests it; a bare `tunnel.sh` there could collide with a cron tick starting the
tunnel at the same moment. A gate that does not confirm a working tunnel prints
a warning.

A staged file that already matches the installed one is dropped, and when none
differs the tunnel is not stopped: a repeated sync, or a wiki-only commit through
the Git updater, used to interrupt WARP for nothing. After the promotion a sync
from a checkout without uncommitted changes writes its commit to
`.deployed_commit`, so the Git updater does not promote the deploy branch over
it.

`.env` gets the same protection as `config.json`: the router's copy can hold
keys the Mac's lacks (the Git updater's `GITHUB_*`), so a differing one stops the
sync unless `--force` is given. It is compared by hash and never pulled.

`usque-rs` is sent only to a router that has none. A router binary that differs
from the local one is kept and a note is printed, because the router's
`fetch_usque_rs.sh` keeps the pinned release while the Mac's copy, fetched once,
goes stale. Pushing it downgraded the router for good: `.usque_release_sha` is
not shipped, so the fetcher still read the pinned release as installed.
`--push-binary` sends the local binary anyway (`--force` alone does not). The deployment that introduced `lock.sh` (2026-10-23)
held the lock the old way, with an ownerless `mkdir`, because the old health
check treated `lock.sh`'s owner file as stale (report section 19.6).

The router copy of `blocked_sites.txt` may be edited independently. Sync refuses
to overwrite divergent content unless `--force` is explicitly supplied. Use
`sync_from_router.sh` to pull it first when appropriate.

`config.json` gets the same protection, because `rotate_tunnel_ip.sh` registers
new WARP identities on the router and leaves the local copy stale. Only SHA-256
hashes are compared; the file holds the private key and is never printed. A
router without a registration (first deploy) is not blocked.

## First-time bootstrap and firmware upgrade survival

`bootstrap_router.sh` registers `/root/router-script/` and `/etc/router-script/`
in `/etc/sysupgrade.conf` so firmware upgrades preserve the router infrastructure
(audit F46). It then runs, in order, `configure_wifi.sh`, `configure_dns.sh`,
`configure_lan_ipv6.sh`, `install_cron_pipeline.sh`, `install_firewall_hook.sh`
(the fw3 include, [[health-recovery]]) and one `ensure_network.sh` pass.
`install_cron_pipeline.sh` installs the twice-per-minute health check, the
15-minute `update_from_git.sh` updater, and the six-hour log rotation and
diagnostic snapshot tasks.

## Git CD updater (`update_from_git.sh`)

When `GITHUB_REPO` is set in `.env` (with `GITHUB_TOKEN` for a private repo),
`update_from_git.sh` checks `DEPLOY_BRANCH` (default `deploy`) every 15 minutes:
- verifies all GitHub Actions check-runs on the commit completed and succeeded;
- downloads the commit tarball, checks `sh -n` syntax on every script, and
  promotes the deployable files via `promote_staged.sh` under `lock.sh`;
- restarts the tunnel the promotion stopped while holding the maintenance lock,
  so a health tick cannot stop a half-started client;
- runs `ensure_network.sh` as a gate (`ROUTER_SCRIPT_TRIGGER=gate`,
  [[health-recovery]]) and records `.deployed_commit` only when it exits 0, which
  means WARP was tested and works; otherwise it rolls back to the pre-update
  backup at once.
- a gate that could not test WARP (exit 75) is rolled back too, but not recorded
  as failed: the next run tries the commit again. Updates are not started at all
  in game mode or while an interactive portal login is pending, when the gate
  could not test WARP. `fetch_usque_rs.sh` applies the same three rules to a new
  binary.
- a commit that failed the health gate is recorded in `.git_failed_commit` and
  skipped on later runs (no 15-minute retry loop). The skip ends when the deploy
  branch moves to another commit, when the file is removed, or with
  `update_from_git.sh --retry-failed`. The file is router-local, gitignored and
  never shipped or deleted by sync/promote.

The git updater keeps its own `DEPLOY_FILES` list. It must equal `FILES` in
`sync_to_router.sh`, in the same order, minus the Mac-only `config.json`, `.env`
and `blocked_sites.txt`; `tests/test_sync.py` asserts this.

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
- `../../../update_from_git.sh`, `../../../.github/workflows/ci.yml`
- `../../../sync_from_router.sh`
- `../../../bootstrap_router.sh`
- `../../../install_cron_pipeline.sh`, `../../../install_firewall_hook.sh`

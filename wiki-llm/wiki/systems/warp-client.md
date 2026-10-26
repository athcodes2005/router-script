# Rust WARP MASQUE client integration

The Rust client source and its internal `wiki-llm` documentation now live in the
dedicated repository **`athcodes2005/usque-rs-openwrt`**
(`/Users/atharva/projects/usque-rs-openwrt`). `router-script` consumes the
compiled static `aarch64-unknown-linux-musl` release binary (`usque-rs`) via
`fetch_usque_rs.sh` and invokes it from `tunnel.sh`.

## Binary delivery (`fetch_usque_rs.sh`)

- `defaults.sh` sets `USQUE_REPO=athcodes2005/usque-rs-openwrt`,
  `USQUE_RELEASE_TAG=latest`, and
  `USQUE_ASSET_NAME=usque-rs-aarch64-linux-musl.tar.gz`.
- `fetch_usque_rs.sh` downloads `.sha256` from the GitHub Release, compares it
  with `.usque_release_sha`, downloads and verifies the archive when updated,
  checks `./usque-rs nativetun --help`, backs up the previous binary to
  `usque-rs-upstream-v0.1.0`, promotes under `lock.sh`, restarts WARP, and
  rolls back to `usque-rs-upstream-v0.1.0` if `ensure_network.sh` fails.
- `update_from_git.sh` runs `fetch_usque_rs.sh` automatically every 15 minutes
  when `AUTO_FETCH_USQUE=1` (default), and `sync_to_router.sh` runs
  `fetch_usque_rs.sh --download-only` on the Mac when `usque-rs` is absent.

## CLI contract with `tunnel.sh`

`tunnel.sh` inspects `./usque-rs nativetun --help` before passing optional flags
so older rollback binaries remain compatible:
- `--congestion-control <cubic|bbr|bbr2|reno>` (from `WARP_CC` in `.env`, `bbr2`
  in production).
- `--ready-file <PATH>` (`WARP_READY_FILE`): `tunnel.sh` waits up to 25 s for
  this PID marker before installing public default routes.
- `--syslog`: logs session lifecycle and disconnect reasons to `logread -e usque-rs`.
- `--upload-codel <MS>` (from `WARP_UPLOAD_CODEL`, off by default).
- `--tun-backpressure <N>` (from `WARP_TUN_BACKPRESSURE`, off by default).

## Sources

- `../../../fetch_usque_rs.sh`, `../../../tunnel.sh`, `../../../defaults.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt` (`/Users/atharva/projects/usque-rs-openwrt/wiki-llm/wiki/index.md`)

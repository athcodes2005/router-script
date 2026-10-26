# Rust WARP MASQUE client integration

The Rust client source and its internal `wiki-llm` documentation now live in the
dedicated repository **`athcodes2005/usque-rs-openwrt`**
(`/Users/atharva/projects/usque-rs-openwrt`). `router-script` consumes the
compiled static `aarch64-unknown-linux-musl` release binary (`usque-rs`) via
`fetch_usque_rs.sh` and invokes it from `tunnel.sh`.

## Binary delivery (`fetch_usque_rs.sh`)

- `defaults.sh` sets `USQUE_REPO=athcodes2005/usque-rs-openwrt`,
  `USQUE_RELEASE_TAG=v0.2.1` (pinned: a new release reaches the router only
  after the tag is bumped in a commit; `latest` still works when set in `.env`), and
  `USQUE_ASSET_NAME=usque-rs-aarch64-linux-musl.tar.gz`.
- `fetch_usque_rs.sh` downloads `.sha256` from the GitHub Release, compares it
  with `.usque_release_sha`, downloads and verifies the archive when updated,
  checks `./usque-rs nativetun --help`, backs up the previous binary to
  `usque-rs.prev` (router-local, never shipped by sync or git), promotes under
  `lock.sh`, restarts WARP, and rolls back to it if `ensure_network.sh` fails
  (falling back to the legacy `usque-rs-upstream-v0.1.0` if `usque-rs.prev` is
  missing). An
  archive that failed the health check is recorded in `.usque_failed_sha` and
  skipped on later runs until the release sha changes, the file is removed, or
  `fetch_usque_rs.sh --retry-failed` is used (router-local, gitignored, never
  shipped or deleted by sync/promote).
- `update_from_git.sh` runs `fetch_usque_rs.sh` automatically every 15 minutes
  when `AUTO_FETCH_USQUE=1` (default), and `sync_to_router.sh` runs
  `fetch_usque_rs.sh --download-only` on the Mac when `usque-rs` is absent.

## CLI contract with `tunnel.sh`

`tunnel.sh` inspects `./usque-rs nativetun --help` before passing optional flags
so older rollback binaries remain compatible:
- `--mtu <MTU>` (`TUN_MTU=1320` in `defaults.sh`, matching `usque-rs` `v0.2.0`'s
  1,320 B dynamic datagram IP payload ceiling `[I4]`; `tunnel.sh` and
  `ensure_network.sh` also enforce `mtu 1320` on `tun0` and bidirectional TCP
  MSS clamping at `1280` IPv4 / `1260` IPv6).
- `--congestion-control <cubic|bbr|bbr2|reno>` (from `WARP_CC` in `.env`, `bbr2`
  in production).
- `--ready-file <PATH>` (`WARP_READY_FILE`): `tunnel.sh` waits up to 25 s for
  this PID marker before installing public default routes.
- `--syslog`: logs session lifecycle and disconnect reasons to `logread -e usque-rs`.
- `--upload-codel <MS>` (from `WARP_UPLOAD_CODEL`, default 20; `0` turns it off).
- `--tun-backpressure <N>` (from `WARP_TUN_BACKPRESSURE`, off by default).
- `--udp-recv-buffer <BYTES>` (from `WARP_UDP_RECV_BUFFER`, empty by default so
  the binary's built-in 4 MiB applies; usque-rs v0.2.2+). `0` means the kernel
  default; the client uses `SO_RCVBUFFORCE` and falls back to `SO_RCVBUF`.
  `tunnel.sh` passes values 0-67108864 only when `nativetun --help` lists the
  flag; a non-number or out-of-range value logs a warning and is ignored, and
  an older binary logs one warning and still starts. A 2026-10-26 test showed
  the 4 MiB buffer cut `RcvbufErrors` during downloads from hundreds or
  thousands to 0 and download loss from 11-23% to 0-8%, at 5-7 MB client RSS.

## `v0.2.0` WARP audit optimizations (deployed 2026-10-26)

1. **`[I1]` Asymmetric QUIC datagram queues:** `DGRAM_RECV_QUEUE_LEN = 8192`
   absorbs bursty downloads without silent RFC 9221 datagram drops while keeping
   `DGRAM_SEND_QUEUE_LEN = 1000`.
2. **`[I2]` QUIC 0-RTT & TLS 1.3 session resumption:** caches
   `Connection::session()` tickets after SPKI verification and `CONNECT-IP`
   readiness and offers them on reconnect via `set_session()` +
   `enable_early_data()`.
3. **`[I4]` Dynamic 1,320 B datagram IP MTU:** `effective_datagram_ip_mtu`
   derives the 1,320 B IP ceiling from `dgram_max_writable_len() = 1322 B` minus
   the 2-byte MASQUE prefix.
4. **`v0.2.1` Sub-ms pacing coalescing & `[I3]` `sendmmsg` batching:** coalesces
   `< 500 µs` pacing deadlines into `UdpSendBatch` (flushed via `sendmmsg(2)`)
   and drains up to 64 ready TUN packets per wakeup (`try_read_tun_packet`). Live
   measurement on 2026-10-26 reached **133.3 Mbit/s upload** with **13/19/28 ms**
   loaded upload RTT (down from 46 ms median on `v0.2.0`) and **5/5/14 ms**
   loaded download RTT at **90.3 Mbit/s**.

## Sources

- `../../../fetch_usque_rs.sh`, `../../../tunnel.sh`, `../../../defaults.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt` (`/Users/atharva/projects/usque-rs-openwrt/wiki-llm/wiki/index.md`)

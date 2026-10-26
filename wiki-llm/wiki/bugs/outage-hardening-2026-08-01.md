# Outage hardening audit — 2026-08-01

This audit covered every top-level shell script, all Rust WARP client modules,
the live router state, and the observed Hostel 01 campus topology. It reduces
identified local outage paths; it cannot make IITB or Cloudflare infallible.

## Failure modes corrected

- Public defaults could be installed when `tun0` existed but CONNECT-IP was not
  ready. The client now emits a readiness marker and startup rolls back on timeout.
- The nominal QUIC keepalive timer sent no network traffic. It now sends an
  ACK-eliciting frame to preserve idle sessions and detect dead peers.
- Reconnect failures leaked detached statistics tasks. A drop guard aborts each
  task when its session leaves the loop.
- WARP waited for the first client packet before connecting. It now connects
  immediately, removing first-request delay and a misleading startup state.
- IPv4 options were checksummed as a 20-byte header and malformed IHL values
  could reach invalid slices. Full-IHL validation and checksumming were added.
- Tunnel startup failures could leave partial routes or processes. A failure
  trap now invokes the idempotent teardown path.
- Health locking used age alone and could evict a slow live check. Locks now
  validate an owner PID and process command line.
- A transient optional campus hostname lookup could trigger WAN cycling. Core
  campus reachability and optional dynamic exceptions are now separate checks.
- Wi-Fi configuration was checked without verifying that radios were actually
  running. Live ubus state is checked and down radios are reloaded.
- DNS configuration was checked without dnsmasq liveness or a real campus
  lookup. Both are now active health gates.
- Wi-Fi, DNS, and LAN IPv6 repair actions were not revalidated, allowing a
  failed repair to end in a misleading healthy result. Each repair now has a
  postcondition check and captures diagnostics before failing.
- WAN recovery did not distinguish Ethernet carrier loss from a DHCP problem.
  Both are now recorded and checked.
- Repeated interactive-login fallback could log out and retry every minute. A
  five-minute marker defers retries while allowing browser authentication.
- SSH/SCP operations could hang with WARP stopped or a deployment lock held.
  Management sessions now have connection and keepalive bounds.
- Router-to-workstation sync could replace a good local WARP config with an
  incomplete transfer. Secret state is now staged, minimally validated, and
  atomically promoted; emergency downloads also validate their remote path.
- Signals could release a maintenance lock without terminating its operation,
  and interrupted WARP rotation could strand a removed registration. Signal
  handlers now exit, and rotation transactionally restores the old identity.
- Cron installation now removes its temporary file on success, error, or signal.
- Diagnostics could fill persistent storage. Retention is 24 snapshots and
  project logging falls back to `/tmp` at 97 percent filesystem use.
- Interrupted diagnostic captures and log rotations now remove their partial
  temporary output rather than accumulating corrupt files.

## Validation

- ARM64 Linux formatting and strict Clippy passed.
- 41 Rust unit tests and 23 integration tests passed.
- Shell scripts passed BusyBox `sh -n` on the router and ShellCheck with only
  documented dynamic-source/trap exclusions.
- An isolated router smoke test reached CONNECT-IP readiness in about one second
  without installing routes or touching the production tunnel.

## Remaining boundaries

The pipeline preserves direct campus IPv4 when WARP is unavailable. Public IPv6
depends on WARP. IITB portal/DNS, physical hostel switching, and Cloudflare
MASQUE remain upstream dependencies. See [[known-issues]] and
[[../operations/health-recovery]].

## Sources

- Full workspace and live-router audit performed 2026-08-01.
- `../../../ensure_network.sh`
- `../../../tunnel.sh`
- `../../../login.sh`
- `../../../paths.sh`
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/src/tunnel.rs`
- `https://github.com/athcodes2005/usque-rs-openwrt/blob/main/src/packet.rs`

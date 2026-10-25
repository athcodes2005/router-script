# Router Script Redesign Plan

> **Superseded 2026-07-31:** This is a historical split-routing proposal, not
> the current architecture. Public IPv4 and IPv6 now use the WARP full tunnel;
> campus-private `10.0.0.0/8` and WARP transport endpoints remain direct.
> See `PROJECT_CONTEXT.md` and `README.md` for current behavior.

## Architecture Change: Split Routing + DNS Optimization + Cleanup

### Current State
- **All** IPv4 and IPv6 public traffic routes through `tun0` (WARP tunnel)
- DNS: `dnsmasq` → `dnscrypt-proxy` (DoH) for everything except campus domains
- This causes: slow speeds (all traffic through tunnel), outages when tunnel drops, high CPU from DoH

### New Design

#### 1. Routing: IPv4 direct, tunnel for IPv6 + blocked sites only

**Before:** `default dev tun0 metric 5` catches all traffic
**After:**
- IPv4 default route stays on `eth0` (campus WAN) — raw campus speed
- IPv6 default route goes through `tun0` (campus has no native IPv6)
- A **blocklist file** (`blocked_sites.txt`) lists IPv4 destinations that need tunnel routing
  - Format: one IP/CIDR per line, comments with `#`
  - `tunnel.sh` reads this file and adds `ip route` entries through `tun0` for each
  - User adds entries as they discover blocks

**Changes to `tunnel.sh`:**
- Remove IPv4 `default dev tun0` route — keep IPv4 default on eth0
- Keep IPv6 `default dev tun0` route
- Read `blocked_sites.txt` and add per-entry routes through `tun0`
- Keep NAT/forwarding/MSS clamp for both v4 and v6 on `tun0` (needed for blocklist traffic + all v6)

**Changes to `stop_tunnel.sh`:**
- Remove blocklist routes on teardown
- Keep IPv6 cleanup as-is

**Changes to `ensure_network.sh`:**
- `internet_v4_ok()` already checks via `eth0` — no change needed
- `tunnel_healthy()` check via `tun0` stays — validates tunnel works for IPv6/blocklist
- Remove `public_v6_ok` as separate step — fold into `tunnel_healthy`

#### 2. DNS: Plain DNS first, DoH as fallback only

**Before:** All DNS goes through `dnscrypt-proxy` (DoH) — CPU heavy
**After:** Priority chain: `8.8.8.8` → `8.8.4.4` → `10.200.1.11` → DoH fallback

**Implementation:**
- Configure `dnsmasq` with `strict-order` and multiple servers:
  1. `server=8.8.8.8`
  2. `server=8.8.4.4`
  3. `server=10.200.1.11`
  4. `server=127.0.0.1#5453` (dnscrypt-proxy DoH, last resort)
- Keep `dnscrypt-proxy` running but only as the last fallback
- Campus-specific domains (`internet.iitb.ac.in`, `sso.iitb.ac.in`) still go to `10.200.1.11` via dnsmasq `server=/domain/10.200.1.11`
- Remove the `forwarding-rules.txt` approach (that was dnscrypt-proxy specific)
- Keep `block_ipv6 = false` in dnscrypt-proxy config

**Changes to `configure_dns.sh`:**
- Set `dnsmasq` servers: `8.8.8.8`, `8.8.4.4`, `10.200.1.11`, `127.0.0.1#5453`
- Enable `strict-order` so dnsmasq tries them in order
- Add `server=/internet.iitb.ac.in/10.200.1.11` and `server=/sso.iitb.ac.in/10.200.1.11` for campus domains
- Remove `noresolv` (we want dnsmasq to use multiple upstreams, not just one)
- Keep dnscrypt-proxy running as last-resort upstream

**Changes to `ensure_network.sh` DNS drift check:**
- Update `dns_config_ok()` to validate the new multi-server setup instead of single upstream

#### 3. File Cleanup

**Remove redundant files:**
- `collect_emergency_diagnostics.sh` — identical to `collect_diagnostics.sh` except filename prefix. Merge into one script with a flag.
- `rotate_tunnel_ip.sh` — rarely used utility, can be a function or documented one-liner

**Clean up:**
- `sync_to_router.sh` — use `rsync` instead of `scp -r` (faster, delta-only, excludes `.DS_Store`/logs/diagnostics)
- `sync_from_router.sh` — use `rsync` for consistency
- `paths.sh` — remove legacy log migration code (the migration from `*.logs` to `logs/*.log` is long done)
- `diagnose.sh` — remove the `dns_flow.sh` call (it duplicates checks already in diagnose.sh)
- Purge local `diagnostics/` and `logs/` — these are stale (from March 18). Fresh ones will come from `sync_from_router.sh`

**New file:**
- `blocked_sites.txt` — blocklist for IPv4 destinations that need tunnel routing

### 4. Updated File Structure

```
router-script/
├── .env                          # credentials
├── config.json                   # usque-rs registration
├── usque-rs                      # WARP binary
├── blocked_sites.txt             # NEW: IPv4 blocklist for tunnel routing
├── paths.sh                      # shared path helpers (cleaned)
├── login.sh                      # captive portal auth (unchanged)
├── tunnel.sh                     # start tunnel + split routing (REWRITTEN)
├── stop_tunnel.sh                # stop tunnel (UPDATED)
├── configure_dns.sh              # DNS setup (REWRITTEN)
├── configure_lan_ipv6.sh         # LAN IPv6 setup (unchanged)
├── ensure_network.sh             # health check pipeline (UPDATED)
├── diagnose.sh                   # diagnostics (CLEANED)
├── collect_diagnostics.sh        # save diagnostic snapshot (UPDATED - merged emergency)
├── dns_flow.sh                   # DNS flow viewer (CLEANED)
├── rotate_logs.sh                # log rotation (unchanged)
├── install_cron_pipeline.sh      # cron setup (unchanged)
├── bootstrap_router.sh           # one-shot setup (UPDATED)
├── sync_to_router.sh             # local→router sync (REWRITTEN with rsync)
├── sync_from_router.sh           # router→local sync (REWRITTEN with rsync)
├── download_emergency_diagnostics.sh  # Mac→router emergency capture (UPDATED)
├── PROJECT_CONTEXT.md            # architecture docs (UPDATED)
├── README.md                     # usage docs (UPDATED)
├── logs/                         # synced logs
└── diagnostics/                  # synced diagnostics
```

**Removed files:**
- `collect_emergency_diagnostics.sh` (merged into `collect_diagnostics.sh --emergency`)
- `rotate_tunnel_ip.sh` (documented as manual steps in README)

### 5. Execution Order

1. Edit all scripts locally
2. Create `blocked_sites.txt` with initial empty template
3. Update `PROJECT_CONTEXT.md` and `README.md`
4. `sync_to_router.sh` to push changes
5. SSH into router and test:
   - Stop current tunnel
   - Run `configure_dns.sh` — verify DNS chain works
   - Run `tunnel.sh` — verify IPv6 through tunnel, IPv4 direct
   - Run `ensure_network.sh` — verify health checks pass
   - Run `diagnose.sh` — full validation
6. Run `bootstrap_router.sh` to reinstall cron
7. Monitor for 5-10 minutes

# Direct-WAN host routes

Some destinations must leave through the campus WAN even while WARP is the
default:
- campus pages that check the source address;
- apps that reject shared VPN egress (Blinkit, Gemini, Supercell);
- active game sessions.

Each gets `/32` routes via the WAN gateway at metric 1, recorded in a state
file under `/tmp`.

## Refreshers

| Refresher | Source of addresses | Ownership record |
|---|---|---|
| Campus | `CAMPUS_DIRECT_DOMAINS`, resolved by campus DNS | `router-script-campus-host-routes` |
| Public | `DIRECT_PUBLIC_DOMAINS`, resolved by dnsmasq | `router-script-direct-public-host-routes` |
| Game session | conntrack flows to port 9339 | `router-script-game-session-host-routes` |
| Blinkit | upstream answers that `refresh_blinkit_dns.sh` publishes | the Blinkit hosts file |

## Lifecycle

- **Refresh.** `ensure_network.sh` refreshes the campus, public and
  game-session sets after each healthy check, with three-second lookup bounds.
  These routes never decide whether WARP is alive.
- **Removal.** A failed or partial resolution keeps the prior routes. Stale
  routes are removed only after every configured name produced IPv4 answers and
  installation succeeded. This avoids CDN-answer races and restarts caused by
  partial DNS failures.
  The game-session refresher differs: it has no names to resolve and rescans
  conntrack. It removes routes that no longer appear only when a scan finds at
  least one live game flow (and installs at least one route). When no game flow
  exists, it keeps the old routes and state file untouched, so the last
  session's `/32` routes persist until a later scan finds a flow or
  `stop_tunnel.sh` runs. A scan killed midway can also leak its small temporary
  file in `/tmp`.
- **Shared routes.** Refreshers can share a `/32` (a game server can also be a
  listed public name), so a route is deleted only once no refresher's file
  lists it.
- **At start.** `tunnel.sh` only adds these routes when WARP starts and never
  removes any, so the health check's refresher is the only remover (commit
  `dcc7e10`).
- **Blinkit.** `refresh_blinkit_dns.sh` runs on every tick, including during
  WARP fallback and game mode, when the public refresher does not run. When the
  Blinkit record set changes, it removes the dropped addresses' routes itself,
  after publishing the new set. It leaves any route another refresher lists to
  that refresher (commit `775bcd4`). Before that commit, sets replaced in those
  states kept their routes until reboot; the router held 20 such routes, which
  were removed by hand on 2026-10-22.
- **Stop.** `stop_tunnel.sh` removes every listed route and the state files.

## Sources

- `../../../ensure_network.sh`, `../../../tunnel.sh`, `../../../stop_tunnel.sh`
- `../../../refresh_blinkit_dns.sh`
- [[policy-routing]], [[../flows/traffic-routing]], [[../operations/health-recovery]]

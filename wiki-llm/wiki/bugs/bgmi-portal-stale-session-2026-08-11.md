# BGMI match-load outage and stale portal recovery — 2026-08-11

BGMI could open and begin matchmaking, but a match stalled near 65 percent with
a network error. The game exposed a short campus Internet authorization outage;
the WARP tunnel, router radio, and game NAT path were not the failing layers.

## Incident evidence

- At 22:10 the direct public-IPv4 grant failed two bounded probes.
- The access-token request completed at the portal's `logout.php`, showing that
  IITB still considered the old session logged in while public forwarding was
  no longer active.
- The previous logic waited through public probes until 22:10:56 before clearing
  that session. A logout and fresh token login restored access at 22:11:04, and
  the full health pipeline passed at 22:11:10.
- The same stale-session pattern appeared in earlier recovery logs that day.
- The hostel gateway averaged about `0.76 ms` with no loss. WARP used BBR2, had
  an empty UDP receive queue, and consumed only seven CPU ticks in ten seconds.
- The active phone's Wi-Fi signal was `-31 dBm`, with negotiated receive and
  transmit rates far above the Internet access rate.

## Game-path evidence

- The core match connection on UDP port 20000 was bidirectional and conntrack
  marked it `ASSURED`; 928 client packets and 1,067 replies were observed.
- UDP port 9031 discovery tried several candidates, and alternatives replied.
- STUN-like UDP port 3478 and a secondary TCP port 17500 flow were also
  bidirectional.
- One auxiliary HTTPS destination did not answer through either WARP or direct
  IITB routing. Because the result was route-independent and the core match
  flow was established, it was not evidence for a BGMI bypass exception.
- Only connection metadata and counters were inspected; no payload was captured
  or retained, and public destination addresses are omitted here.

## Root cause

The access token was not rejected. The portal returned an authenticated-session
destination even though its upstream public forwarding grant had become stale.
Waiting for external probes could not change that server-side state. The delay,
combined with a once-per-minute watchdog, created an outage long enough for the
time-sensitive match bootstrap to fail at 65 percent.

## Permanent repair

- `login.sh` now recognizes a token request ending at `logout.php` while public
  access is down as a stale session and immediately performs logout plus a fresh
  token login.
- Direct checks use two-second connection and four-second overall bounds, a
  two-second confirmation interval, and shorter post-login settling delays.
- The health pipeline runs at both the start and midpoint of every minute. Its
  existing lock prevents the staggered jobs from overlapping.
- Interactive CAPTCHA/SSO remains only the fallback when automatic token
  recovery genuinely fails and creates the explicit marker.
- No Mac settings and no game-specific direct-routing exceptions were changed.

## Verification

Shell syntax and ShellCheck passed before deployment. Timestamped rollback
copies were retained on the router. Consecutive start-of-minute and 30-second
health runs passed after deployment, while the live core match flow remained
bidirectional and `ASSURED`.

## Related pages

See [[../operations/health-recovery]], [[../flows/boot-and-recovery]], and
[[../systems/campus-wan]].

## Sources

- Live router health, Wi-Fi, conntrack, and sanitized portal-log inspection on 2026-08-11.
- `../../../login.sh`
- `../../../ensure_network.sh`
- `../../../install_cron_pipeline.sh`

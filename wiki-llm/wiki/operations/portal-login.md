# Portal login recovery

`login.sh` authenticates the campus captive portal when direct IPv4 is down.
The health check calls it; see [[health-recovery]] for when.

## Token login

The preferred path sends the CC Internet Access token as HTTP Basic Auth and
retains it only across trusted HTTPS redirects, so a valid token needs no
CAPTCHA. The credentials reach curl on stdin (`-K -`), never in its command
line. If the token is expired or revoked, or the portal changes its flow, the
script records an interactive-login marker without logging the page body.

The health loop then waits five minutes between token retries instead of
logging out every minute. A browser login remains the last-resort fallback;
the next direct probe detects that portal grant and starts WARP automatically.

## When recovery starts

Direct IPv4 must fail twice, two seconds apart, before portal recovery starts.
Probes use a two-second connection timeout and a four-second total bound.

If token submission ends at `logout.php` while public access is down,
`login.sh` treats that as a stale server-side grant: it logs out at once and
performs a fresh token login. Other responses still receive bounded rechecks
before the session is cleared. This avoids both logouts triggered by transient
failures and the former dead wait when probes could not repair a stale portal
record.

A certificate failure (curl exit 60, "not yet valid", "certificate has
expired") is logged with a hint to check the router clock. After a reboot it can
be months behind until NTP syncs.

## Sources

- `../../../login.sh`
- `../../../ensure_network.sh`
- [[../security/secrets-and-trust]]

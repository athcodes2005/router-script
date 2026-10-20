# Intermittent game latency audit — 2026-09-19

BGMI on iPhone and Clash Royale on iPad intermittently lagged, mostly on 5 GHz.
The audit identified avoidable recovery paths but did not capture an in-game
spike; the precise cause of each user-visible incident remains unconfirmed.

## Evidence

The previous day's health log contained 12 WARP restarts and several campus
portal recoveries. Old messages lacked a failure reason. Initial gateway RTT
averaged 0.751 ms with 15/15 replies; public WARP ping averaged 3.948 ms with
15/15 replies. Memory, storage and queue snapshots were healthy, and connected
5 GHz clients had strong signal. These snapshots cannot rule out rare spikes.

## Deployed repairs

- Confirm a live tunnel failure after three seconds; log the failed layer.
- Separate optional domain-route maintenance from tunnel liveness.
- Resolve each domain once per refresh, with a three-second lookup bound.
- Preserve existing routes on partial DNS/installation failure.
- Bind tunnel reachability probes explicitly to the TUN interface.
- Serialize game-mode toggles and retain the fallback WAN gateway on disable.
- Respect game-mode AAAA filtering during LAN IPv6 repair.
- Honor matching portal/SSO pin overrides in configuration and validation.
- Replace the historical hard-coded game monitor with bounded simultaneous
  gateway/client and direct-WAN/WARP measurements and size-limited logs.

## Validation and limits

Eight mocked-command regression tests and local/router shell syntax passed.
Runtime scripts were staged, checksummed and installed under the existing lock.
WARP retained its process across deployment; Wi-Fi and DNS were not restarted.
Six paired probes across 30 seconds returned HTTP 204, gateway packets were not
lost, and a tunnel IPv6 request succeeded. This is not proof that rare game
spikes are eliminated. No background monitor was left running.

Rust modules were source-reviewed, but the Linux build engine was unavailable;
no Rust binary was changed. Remaining test/observability, deployment-lock and
startup-route issues are recorded in the detailed audit report. Campus portal
outages remain external. SQM requires a loaded-latency measurement and measured
rates before selecting a bandwidth cap.

## Related pages

See [[../operations/health-recovery]], [[../operations/diagnostics]],
[[../operations/deployment]], and [[known-issues]].

## Sources

- `../../../audit/2026-09-19/REPORT.md`
- `../../../audit/2026-09-19/changes.patch`
- `../../../tests/test_network_recovery.py`
- `../../../ensure_network.sh`
- `../../../game_mode.sh`
- `../../../monitor_game_network.sh`
- Live router inspection and bounded probes on 2026-09-19.

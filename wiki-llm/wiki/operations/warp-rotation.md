# WARP identity rotation

`rotate_tunnel_ip.sh` requests a fresh WARP registration and replaces the active
identity only after the replacement is proven usable. The operation cooperates
with the health-check maintenance lock.

## Transaction

1. Wait up to thirty seconds to acquire the maintenance lock.
2. Copy the existing `config.json` to `config.json.previous` with mode `0600`.
3. Stop the active tunnel and remove the current config.
4. Run `tunnel.sh`, which registers noninteractively using the explicit config
   path and installs full-tunnel state.
5. Verify the WARP process and active public IPv4 and IPv6 connectivity.

## Success

On success, the backup is deleted and the new registration remains active. The
current endpoint from the new config is automatically included in direct-WAN
transport routes.

## Rollback

On any failure, the script stops partial tunnel state, restores the previous
mode-`0600` config, and restarts the old tunnel. It returns failure so automation
or an operator can distinguish a rollback from successful rotation.

## Concurrency

The lock prevents the minute health check from interpreting intentional tunnel
teardown as an outage. Trap cleanup releases the lock on normal exit or signal.

## Sources

- `../../../rotate_tunnel_ip.sh`
- `../../../tunnel.sh`
- `../../../stop_tunnel.sh`
- [[security/secrets-and-trust]]

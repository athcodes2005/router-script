# Wi-Fi stability profile

The router serves LAN clients on MediaTek 2.4 GHz and 5 GHz radios. Gaming
latency depends on this local radio link as well as WAN and WARP health.

## Diagnosed configuration

The live router was configured for regulatory country `US` while physically
operating in India. Its 5 GHz radio also used `HE160`. Recent driver logs showed
client disconnects, repeated block-ack compatibility warnings, and one burst of
continuous transmit failures before a station was removed.

Queueing and tunnel counters showed no corresponding packet drops, and WARP
remained healthy. This isolated the event to the radio/client link rather than
the tunnel data plane.

## Stability policy

- Regulatory country is `IN` on both radios.
- 2.4 GHz uses `HE20` to reduce overlap in dense spectrum.
- 5 GHz uses `HE80` instead of 160 MHz.
- Channel selection remains automatic because the vendor scan interface does
  not provide reliable survey results on this firmware.

An 80 MHz 5 GHz channel retains substantially more PHY capacity than the WAN
requires, while reducing interference exposure and compatibility edge cases.

## Enforcement

`configure_wifi.sh` validates the configured radio sections, changes only
drifted values, commits UCI, and reloads Wi-Fi only when necessary. Environment
variables can override device section names, country, and widths.

`ensure_network.sh` checks this profile each minute and invokes the configurator
on drift. `bootstrap_router.sh` applies it during one-shot setup. A Wi-Fi reload
briefly disconnects clients, but normal healthy checks do not reload the radios.

The live router keeps the pre-change configuration at
`/etc/config/wireless.pre-router-script-20260801`, mode `0600`. Restoring that
file followed by `wifi reload` rolls back the radio policy.

## Sources

- `../../../configure_wifi.sh`
- `../../../ensure_network.sh`
- Live UCI, interface-counter, queue, and kernel-log audit on 2026-08-01.
- [[bugs/known-issues]]

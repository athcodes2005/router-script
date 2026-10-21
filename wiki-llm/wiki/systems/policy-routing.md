# Policy-routing rules and mark bits

IPv4 policy routing is shared with GL.iNet's firmware. Our three rules run
after GL.iNet's rule 1 and before its rule 800, and our marks use bits 16–20.
Check both tables before adding a rule or a mark.

## Rule order

The lowest priority number is evaluated first.

| Priority | Owner | Rule | Purpose |
|---|---|---|---|
| 0 | kernel | `lookup local` | Local addresses |
| 1 | GL.iNet | `iif lo lookup 16800` | Router-originated traffic; table contents not captured |
| 690 | ours | `oif tun0 lookup main` | Sockets bound to `tun0` (health probes) keep testing WARP |
| 700 | ours | `fwmark 0x40000/0xf0000 lookup 101` | Game sessions (port 9339) use the WAN |
| 710 | ours | `fwmark 0x100000/0x100000 lookup 102` | Google IPv4 uses the WAN |
| 800 | GL.iNet | `lookup 9910 suppress_prefixlength 0` | Not determined |
| 1099 | GL.iNet | `fwmark 0x80000/0xc0000 lookup main` | Not determined |
| 1101 | GL.iNet | `not fwmark 0x8000/0xc000 lookup 8000` | Not determined |
| 6000 | GL.iNet | `fwmark 0x8000/0xf000 lookup main` | Marked LAN traffic uses `main` |
| 9000 | GL.iNet | `not fwmark 0/0xf000 lookup main` | Any GL.iNet mark uses `main` |
| 9910 | GL.iNet | `not fwmark 0/0xf000 blackhole` | Marked traffic `main` cannot route is dropped |
| 9920 | GL.iNet | `iif br-lan blackhole` | LAN traffic that no earlier rule routed is dropped |
| 32766, 32767 | kernel | `lookup main`, `lookup default` | Defaults |

Rule 690 and 710 come from `google_wan_policy.sh`; rule 700 from `tunnel.sh` and
`ensure_network.sh`. GL.iNet's rules are from the 2026-08-01 snapshot, taken
before 690–710 existed. Firmware updates or GL.iNet's VPN-policy settings may
change them. The snapshot holds no mangle rules and no `ip -6 rule` output, so
which component sets GL.iNet's marks is inferred, and IPv6 is not covered (our
game and Google policies are IPv4 only).

## Mark bits

| Bits | Mask | Owner | Use |
|---|---|---|---|
| 12–15 | `0xf000`, `0xc000` | GL.iNet | Rules 1101, 6000, 9000, 9910 |
| 16–19 | `0xf0000` | ours | Game mark `0x40000` (bit 18), saved to and restored from the connmark with the same mask |
| 18–19 | `0xc0000` | GL.iNet | Rule 1099 matches `0x80000` (bit 19) |
| 20 | `0x100000` | ours | Google mark |

**Overlap (audit F24).** The game mask covers GL.iNet's rule-1099 bits:
`--set-xmark 0x40000/0xf0000` clears bit 19, and a later GL.iNet rule setting
`0x80000/0xc0000` would clear bit 18, so rule 700 would miss and the session
would use WARP. No breakage is known, and whether GL.iNet ever sets bit 19 on
LAN traffic is unknown. Leave the mask unchanged without evidence.

## Adding a rule or a mark

- Use a bit that no table above uses (21 or higher), with a single-bit mask.
- Keep new priorities in 690–799, after GL.iNet's rule 1 and before 800.
- Add a rule only when `ip rule show` lacks it; never delete and re-add one
  every tick (audit F08).

Read-only checks: `ip rule show` and `iptables -t mangle -S | grep -i mark`.

## Sources

- `../../../google_wan_policy.sh`, `../../../tunnel.sh`, `../../../ensure_network.sh`
- `../../../diagnostics/diagnostic_20260801_193111_6385.log` (policy-rule section)
- `../../../audit/2026-10-20-full-review/REPORT.md` (F08, F24)
- [[google-wan]], [[../flows/traffic-routing]]

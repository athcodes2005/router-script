# Router project wiki

Start with [[overview]] for purpose and boundaries, then [[architecture]] for
the active topology. This index lists every maintained wiki page.

## Core

- [[overview]] — project goals, platform, and operating contract.
- [[architecture]] — components and the active full-tunnel design.
- [[sources]] — source inventory, authority, and excluded secrets.
- [[log]] — append-only wiki and audit history.

## Systems

- [[systems/script-map]] — responsibilities of every top-level project file.
- [[systems/warp-client]] — Rust MASQUE client modules and lifecycle.
- [[systems/google-wan]] — Google/YouTube direct IITB routing and IPv6 fallback.
- [[systems/dns]] — resolver chain and campus-domain forwarding.
- [[systems/campus-wan]] — Hostel 01 addressing, gateway, DNS, and campus hops.
- [[systems/policy-routing]] — rule priorities and mark bits, ours and GL.iNet's.
- [[systems/host-routes]] — direct-WAN `/32` exceptions, their refreshers and removal rules.
- [[systems/ipv6]] — LAN IPv6 addressing, advertisement, NAT, and routing.
- [[systems/wifi]] — radio stability profile and drift repair.

## Operations

- [[operations/deployment]] — safe synchronization and bootstrap procedure.
- [[operations/health-recovery]] — staggered health pipeline and direct fallback.
- [[operations/portal-login]] — campus portal token login and stale-session recovery.
- [[operations/diagnostics]] — evidence collection, retention, and triage.
- [[operations/warp-rotation]] — safe WARP registration rotation and rollback.

## Flows

- [[flows/traffic-routing]] — packet paths for public and campus traffic.
- [[flows/boot-and-recovery]] — boot ordering and failure-state transitions.

## Bugs, security, and policy

- [[bugs/tmp-exhaustion-2026-08-01]] — diagnosed sluggish-Wi-Fi incident.
- [[bugs/outage-hardening-2026-08-01]] — failure-mode audit and mitigations.
- [[bugs/warp-cpu-spin-2026-08-07]] — QUIC timer spin and sluggish-tunnel incident.
- [[bugs/warp-forwarding-starvation-2026-08-09]] — unbounded UDP drain starvation and fair-batching repair.
- [[bugs/bgmi-portal-stale-session-2026-08-11]] — BGMI match failure caused by a stale campus portal session.
- [[bugs/ipv6-repair-loop-2026-08-13]] — failed ULA assignment trapped recovery in repeated LAN reloads.
- [[bugs/campus-site-routing-2026-08-14]] — Moodle and ASC were missing from campus DNS/direct routing.
- [[bugs/campus-dns-outage-2026-08-19]] — campus DNS outage blocked captive-portal resolution and room egress.
- [[bugs/mulyankan-internal-dns-2026-08-20]] — Mulyankan required campus split DNS and router-provided client DNS.
- [[bugs/blinkit-warp-egress-2026-09-10]] — Blinkit endpoints required direct WAN egress instead of shared WARP.
- [[bugs/blinkit-ipv6-vpn-warning-2026-09-19]] — IPv6 gap and captured legacy API omitted from the Blinkit bypass.
- [[bugs/webmail-split-dns-2026-09-12]] — Webmail required campus split DNS instead of its public address.
- [[bugs/gemini-warp-egress-2026-09-17]] — Gemini anti-abuse warning required direct IPv4 egress.
- [[bugs/clash-royale-warp-port-2026-09-22]] — Clash Royale’s game-session port required direct WAN egress.
- [[bugs/game-latency-audit-2026-09-19]] — intermittent game latency, recovery hardening, validation and remaining limits.
- [[bugs/opencode-pqc-mss-clamping-2026-10-08]] — OpenCode Post-Quantum TLS failure resolved via bidirectional MSS clamping.
- [[bugs/full-review-2026-10-20]] — October 2026 full review (F01–F52), firmware 4.11.0 audit, and Git CD pipeline.
- [[bugs/known-issues]] — limitations and remaining operational risks.
- [[security/secrets-and-trust]] — credentials, file modes, and endpoint trust.
- [[policies/architecture-decisions]] — current design decisions and rationale.

## Sources

- All pages linked above.
- `../../README.md`
- `../raw/sources/project-context-2026-10-25.md`

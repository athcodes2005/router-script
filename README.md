# IITB OpenWrt Router Scripts

Resilient Cloudflare WARP (MASQUE over QUIC) gateway, campus split-DNS, policy routing, and self-healing health pipeline for a GL.iNet GL-MT3000 router in IIT Bombay.

All architecture, system specifications, operational procedures, incident history, and audit sources live in **[`wiki-llm/wiki/index.md`](wiki-llm/wiki/index.md)**:

- **Overview & Architecture:** [`wiki-llm/wiki/overview.md`](wiki-llm/wiki/overview.md) · [`wiki-llm/wiki/architecture.md`](wiki-llm/wiki/architecture.md)
- **Deployment & Git CD:** [`wiki-llm/wiki/operations/deployment.md`](wiki-llm/wiki/operations/deployment.md) · [`wiki-llm/wiki/operations/health-recovery.md`](wiki-llm/wiki/operations/health-recovery.md)
- **Wiki Maintenance Contract:** [`wiki-llm/AGENTS.md`](wiki-llm/AGENTS.md)

The Rust WARP client (`usque-rs`) is built in the separate repository [`athcodes2005/usque-rs-openwrt`](https://github.com/athcodes2005/usque-rs-openwrt). `fetch_usque_rs.sh` delivers it by downloading a GitHub release pinned by `USQUE_RELEASE_TAG` in `defaults.sh` (currently `v0.2.2`; set `latest` to track new releases) and verifying its sha256.

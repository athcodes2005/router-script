use anyhow::{bail, Context, Result};
use portable_atomic::{AtomicU64, Ordering};
use quiche::h3::NameValue;
use ring::rand::SecureRandom;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::Config;
use crate::icmp;
use crate::packet;
use crate::tls;

const MAX_DATAGRAM_SIZE: usize = 1350;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
// quiche can report a zero-duration timeout while loss recovery is pending.
// Passing that directly to tokio::time::sleep creates a hot loop that can pin
// one router CPU core even when the tunnel is carrying little traffic.
const MIN_EVENT_LOOP_SLEEP: Duration = Duration::from_millis(5);
// Every forwarding stage must eventually yield to the others. In particular,
// an unbounded UDP drain can remain readable indefinitely during a download,
// starving decoded datagrams, TUN writes, and QUIC ACK transmission.
const MAX_FORWARDING_BATCH: usize = 64;
// A failed TUN write loses that one packet. Writes that keep failing mean the
// device is gone, so the session ends instead of silently dropping all traffic.
const MAX_CONSECUTIVE_TUN_WRITE_FAILURES: u32 = 32;

fn event_loop_timeout(quic_timeout: Option<Duration>, keepalive: Duration) -> Duration {
    quic_timeout
        .unwrap_or(keepalive)
        .min(keepalive)
        .max(MIN_EVENT_LOOP_SLEEP)
}

const fn forwarding_batch_limit_reached(index: usize) -> bool {
    index + 1 == MAX_FORWARDING_BATCH
}

fn pacing_delay(send_at: Instant, now: Instant) -> Duration {
    send_at.saturating_duration_since(now)
}

async fn write_tun<W>(
    tun_writer: &mut W,
    packet: &[u8],
    stats: &Stats,
    failures: &mut u32,
) -> Result<()>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    match tokio::io::AsyncWriteExt::write_all(tun_writer, packet).await {
        Ok(()) => {
            *failures = 0;
            Ok(())
        }
        Err(error) => {
            stats.dropped.fetch_add(1, Ordering::Relaxed);
            *failures += 1;
            if *failures >= MAX_CONSECUTIVE_TUN_WRITE_FAILURES {
                bail!("{failures} consecutive TUN writes failed: {error}");
            }
            log::debug!("TUN write failed: {error}");
            Ok(())
        }
    }
}

async fn send_paced_packet(
    socket: &tokio::net::UdpSocket,
    packet: &[u8],
    send_info: quiche::SendInfo,
) -> std::io::Result<usize> {
    let delay = pacing_delay(send_info.at, Instant::now());
    if !delay.is_zero() {
        tokio::time::sleep(delay).await;
    }
    socket.send_to(packet, send_info.to).await
}

/// Configuration for a MASQUE tunnel session.
pub struct TunnelConfig {
    pub endpoint: SocketAddr,
    pub sni: String,
    pub keepalive_period: Duration,
    pub mtu: u32,
    pub congestion_control: String,
    pub ready_file: Option<String>,
}

struct AbortTaskOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortTaskOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn clear_ready_file(path: Option<&str>) {
    let Some(path) = path else {
        return;
    };
    if let Err(error) = std::fs::remove_file(path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            log::warn!("failed to remove readiness marker {path}: {error}");
        }
    }
}

fn mark_ready(path: Option<&str>) -> Result<()> {
    let Some(path) = path else {
        return Ok(());
    };
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create readiness directory for {path}"))?;
    }
    std::fs::write(path, format!("{}\n", std::process::id()))
        .with_context(|| format!("failed to write readiness marker {path}"))
}

struct Stats {
    tx_packets: AtomicU64,
    rx_packets: AtomicU64,
    tx_bytes: AtomicU64,
    rx_bytes: AtomicU64,
    dropped: AtomicU64,
    quic_lost: AtomicU64,
    quic_retrans: AtomicU64,
}

impl Stats {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            tx_packets: AtomicU64::new(0),
            rx_packets: AtomicU64::new(0),
            tx_bytes: AtomicU64::new(0),
            rx_bytes: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            quic_lost: AtomicU64::new(0),
            quic_retrans: AtomicU64::new(0),
        })
    }
}

fn format_bytes(bytes: u64) -> String {
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    const GIB: u64 = 1024 * MIB;
    if bytes >= GIB {
        format!("{:.1} GiB", bytes as f64 / GIB as f64)
    } else if bytes >= MIB {
        format!("{:.1} MiB", bytes as f64 / MIB as f64)
    } else if bytes >= KIB {
        format!("{:.1} KiB", bytes as f64 / KIB as f64)
    } else {
        format!("{bytes} B")
    }
}

fn format_duration(d: Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m {:02}s", secs / 60, secs % 60)
    } else {
        format!(
            "{}h {:02}m {:02}s",
            secs / 3600,
            (secs % 3600) / 60,
            secs % 60
        )
    }
}

/// Run the MASQUE tunnel and reconnect with bounded backoff.
pub async fn maintain_tunnel(
    config: &Config,
    tunnel_cfg: &TunnelConfig,
    tun_dev: tun::Device,
) -> Result<()> {
    let async_dev = tun::AsyncDevice::new(tun_dev)
        .map_err(|e| anyhow::anyhow!("failed to create async TUN device: {e}"))?;
    let (mut tun_reader, mut tun_writer) = tokio::io::split(async_dev);

    let mut reconnect_delay = Duration::from_secs(1);
    clear_ready_file(tunnel_cfg.ready_file.as_deref());

    loop {
        eprintln!("\r\x1b[2K[connecting] {} ...", tunnel_cfg.endpoint);

        let session_result =
            run_tunnel_session(config, tunnel_cfg, &mut tun_reader, &mut tun_writer).await;
        let was_ready = tunnel_cfg
            .ready_file
            .as_deref()
            .is_some_and(|path| Path::new(path).is_file());
        clear_ready_file(tunnel_cfg.ready_file.as_deref());

        match session_result {
            Ok(()) => {
                eprintln!("\r\x1b[2K[disconnected] Session ended");
                reconnect_delay = Duration::from_secs(1);
            }
            Err(e) => {
                if was_ready {
                    reconnect_delay = Duration::from_secs(1);
                }
                eprintln!("\r\x1b[2K[error] {e:#}");
                eprintln!(
                    "\r\x1b[2K[retry] Waiting {}s before reconnecting",
                    reconnect_delay.as_secs()
                );
                tokio::time::sleep(reconnect_delay).await;
                reconnect_delay = (reconnect_delay * 2).min(MAX_RECONNECT_DELAY);
            }
        }
        // Loop back to idle
    }
}

async fn run_tunnel_session<R, W>(
    config: &Config,
    tunnel_cfg: &TunnelConfig,
    tun_reader: &mut R,
    tun_writer: &mut W,
) -> Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let tls_material = tls::prepare_tls_material(config)?;

    let mut quic_config = quiche::Config::new(quiche::PROTOCOL_VERSION)
        .map_err(|e| anyhow::anyhow!("quiche config: {e}"))?;

    quic_config.verify_peer(false);
    quic_config
        .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
        .map_err(|e| anyhow::anyhow!("set ALPN: {e}"))?;
    let endpoint_pub_key_spki_der = tls_material.load_into(&mut quic_config)?;

    quic_config.set_max_idle_timeout(0);
    quic_config.set_max_recv_udp_payload_size(MAX_DATAGRAM_SIZE);
    quic_config.set_max_send_udp_payload_size(MAX_DATAGRAM_SIZE);
    quic_config.set_initial_max_data(10_000_000);
    quic_config.set_initial_max_stream_data_bidi_local(1_000_000);
    quic_config.set_initial_max_stream_data_bidi_remote(1_000_000);
    quic_config.set_initial_max_stream_data_uni(1_000_000);
    quic_config.set_initial_max_streams_bidi(100);
    quic_config.set_initial_max_streams_uni(100);
    quic_config.set_disable_active_migration(true);
    quic_config.enable_dgram(true, 1000, 1000);
    quic_config
        .set_cc_algorithm_name(&tunnel_cfg.congestion_control)
        .map_err(|e| anyhow::anyhow!("invalid congestion control algorithm: {e}"))?;

    let bind_addr: SocketAddr = match tunnel_cfg.endpoint {
        SocketAddr::V4(_) => "0.0.0.0:0".parse().unwrap(),
        SocketAddr::V6(_) => "[::]:0".parse().unwrap(),
    };

    let socket = tokio::net::UdpSocket::bind(bind_addr).await?;
    socket.connect(tunnel_cfg.endpoint).await?;
    let local_addr = socket.local_addr()?;

    let mut scid = [0u8; quiche::MAX_CONN_ID_LEN];
    ring::rand::SystemRandom::new()
        .fill(&mut scid)
        .map_err(|_| anyhow::anyhow!("RNG failure"))?;
    let scid = quiche::ConnectionId::from_ref(&scid);

    let mut conn = quiche::connect(
        Some(&tunnel_cfg.sni),
        &scid,
        local_addr,
        tunnel_cfg.endpoint,
        &mut quic_config,
    )
    .map_err(|e| anyhow::anyhow!("quiche connect: {e}"))?;

    let mut out = vec![0u8; MAX_DATAGRAM_SIZE];
    let mut buf = vec![0u8; 65535];

    let (write, send_info) = conn
        .send(&mut out)
        .map_err(|e| anyhow::anyhow!("initial send: {e}"))?;
    send_paced_packet(&socket, &out[..write], send_info).await?;

    // Complete handshake with a hard deadline. quiche's idle timeout is
    // intentionally disabled for established sessions, so it cannot also be
    // relied upon to bound a blackholed initial handshake.
    let handshake_started = Instant::now();
    loop {
        if handshake_started.elapsed() >= HANDSHAKE_TIMEOUT {
            bail!("timed out during QUIC handshake");
        }
        let remaining = HANDSHAKE_TIMEOUT.saturating_sub(handshake_started.elapsed());
        let timeout = conn
            .timeout()
            .unwrap_or(Duration::from_millis(100))
            .min(remaining);

        tokio::select! {
            result = socket.recv(&mut buf) => {
                let len = result?;
                let recv_info = quiche::RecvInfo {
                    to: local_addr,
                    from: tunnel_cfg.endpoint,
                };
                conn.recv(&mut buf[..len], recv_info).ok();
            }
            () = tokio::time::sleep(timeout) => {
                conn.on_timeout();
            }
        }

        loop {
            match conn.send(&mut out) {
                Ok((write, send_info)) => {
                    send_paced_packet(&socket, &out[..write], send_info).await?;
                }
                Err(quiche::Error::Done) => break,
                Err(e) => bail!("send during handshake: {e}"),
            }
        }

        if conn.is_established() {
            break;
        }
        if conn.is_closed() {
            bail!("connection closed during handshake");
        }
    }

    // Verify endpoint key pinning
    let peer_cert = conn
        .peer_cert()
        .context("WARP endpoint did not provide a peer certificate")?;
    if !tls::verify_endpoint_key(peer_cert, &endpoint_pub_key_spki_der) {
        bail!("peer certificate public key does not match pinned endpoint key");
    }
    log::debug!("Endpoint key pinning verified");

    // Set up HTTP/3
    let mut h3_config = quiche::h3::Config::new().map_err(|e| anyhow::anyhow!("h3 config: {e}"))?;
    h3_config.enable_extended_connect(true);

    let mut h3_conn = quiche::h3::Connection::with_transport(&mut conn, &h3_config)
        .map_err(|e| anyhow::anyhow!("h3 connection: {e}"))?;

    // Send CONNECT request for cf-connect-ip
    let req = vec![
        quiche::h3::Header::new(b":method", b"CONNECT"),
        quiche::h3::Header::new(b":protocol", b"cf-connect-ip"),
        quiche::h3::Header::new(b":scheme", b"https"),
        quiche::h3::Header::new(b":authority", b"cloudflareaccess.com"),
        quiche::h3::Header::new(b":path", b"/"),
        quiche::h3::Header::new(b"capsule-protocol", b"?1"),
        quiche::h3::Header::new(b"user-agent", b""),
    ];

    let stream_id = h3_conn
        .send_request(&mut conn, &req, false)
        .map_err(|e| anyhow::anyhow!("send CONNECT request: {e}"))?;

    let flow_id = stream_id / 4;
    log::debug!("CONNECT request sent on stream {stream_id}, flow_id={flow_id}");

    loop {
        match conn.send(&mut out) {
            Ok((write, send_info)) => {
                send_paced_packet(&socket, &out[..write], send_info).await?;
            }
            Err(quiche::Error::Done) => break,
            Err(e) => bail!("send after CONNECT: {e}"),
        }
    }

    // Wait for 2xx
    let mut connect_established = false;
    let connect_started = Instant::now();
    for _ in 0..100 {
        if connect_started.elapsed() >= HANDSHAKE_TIMEOUT {
            bail!("timed out waiting for CONNECT response");
        }
        let remaining = HANDSHAKE_TIMEOUT.saturating_sub(connect_started.elapsed());
        let timeout = conn
            .timeout()
            .unwrap_or(Duration::from_millis(100))
            .min(remaining);

        tokio::select! {
            result = socket.recv(&mut buf) => {
                let len = result?;
                let recv_info = quiche::RecvInfo {
                    to: local_addr,
                    from: tunnel_cfg.endpoint,
                };
                conn.recv(&mut buf[..len], recv_info).ok();
            }
            () = tokio::time::sleep(timeout) => {
                conn.on_timeout();
            }
        }

        loop {
            match h3_conn.poll(&mut conn) {
                Ok((sid, quiche::h3::Event::Headers { list, has_body: _ })) if sid == stream_id => {
                    for h in &list {
                        if h.name() == b":status" {
                            let status = std::str::from_utf8(h.value()).unwrap_or("?");
                            log::debug!("CONNECT response status: {status}");
                            if status.starts_with('2') {
                                connect_established = true;
                            } else {
                                bail!("CONNECT rejected with status {status}");
                            }
                        }
                    }
                }
                Ok(_) => {}
                Err(quiche::h3::Error::Done) => break,
                Err(e) => bail!("h3 poll error: {e}"),
            }
        }

        // Flush
        loop {
            match conn.send(&mut out) {
                Ok((write, send_info)) => {
                    send_paced_packet(&socket, &out[..write], send_info).await?;
                }
                Err(quiche::Error::Done) => break,
                Err(e) => bail!("send during CONNECT wait: {e}"),
            }
        }

        if connect_established {
            break;
        }
        if conn.is_closed() {
            bail!("connection closed before CONNECT response");
        }
    }

    if !connect_established {
        bail!("timed out waiting for CONNECT response");
    }

    eprintln!("\r\x1b[2K[connected] MASQUE tunnel established");
    mark_ready(tunnel_cfg.ready_file.as_deref())?;

    let stats = Stats::new();
    let session_start = Instant::now();

    // Spawn stats display task
    let stats_display = stats.clone();
    let stats_handle =
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                let tx_p = stats_display.tx_packets.load(Ordering::Relaxed);
                let rx_p = stats_display.rx_packets.load(Ordering::Relaxed);
                let tx_b = stats_display.tx_bytes.load(Ordering::Relaxed);
                let rx_b = stats_display.rx_bytes.load(Ordering::Relaxed);
                let dropped = stats_display.dropped.load(Ordering::Relaxed);
                let lost = stats_display.quic_lost.load(Ordering::Relaxed);
                let retrans = stats_display.quic_retrans.load(Ordering::Relaxed);
                let uptime = session_start.elapsed();
                eprint!(
                "\r\x1b[2K[connected {}] tx: {} ({})  rx: {} ({})  drop: {}  lost: {}  retrans: {}",
                format_duration(uptime),
                tx_p, format_bytes(tx_b),
                rx_p, format_bytes(rx_b),
                dropped, lost, retrans,
            );
            }
        });
    let _stats_guard = AbortTaskOnDrop(stats_handle);

    // Build the flow_id varint prefix + context_id zero
    let mut flow_prefix = Vec::with_capacity(16);
    {
        let mut tmp = [0u8; 8];
        let mut b = octets::OctetsMut::with_slice(&mut tmp);
        b.put_varint(flow_id).unwrap();
        let len = b.off();
        flow_prefix.extend_from_slice(&tmp[..len]);
    }
    flow_prefix.push(0x00);

    // Main data forwarding loop
    let mtu = tunnel_cfg.mtu as usize;
    let mut tun_buf = vec![0u8; mtu + 128];
    let mut dgram_buf = vec![0u8; mtu + flow_prefix.len() + 128];
    let keepalive_interval = tunnel_cfg.keepalive_period;
    let mut last_keepalive = Instant::now();
    let mut last_quic_stats_update = Instant::now();
    let mut internal_work_pending = false;
    let mut paced_packet: Option<(Vec<u8>, quiche::SendInfo)> = None;
    let mut tun_write_failures = 0;

    let result: Result<()> = loop {
        let timeout = event_loop_timeout(conn.timeout(), keepalive_interval);
        let paced_send_delay = paced_packet
            .as_ref()
            .map_or(keepalive_interval, |(_, info)| {
                pacing_delay(info.at, Instant::now())
            });

        tokio::select! {
            // Read from TUN -> send to QUIC
            result = tokio::io::AsyncReadExt::read(tun_reader, &mut tun_buf) => {
                let n = result?;
                if n == 0 {
                    bail!("TUN device closed");
                }

                let pkt = &mut tun_buf[..n];
                match packet::prepare_outgoing(pkt) {
                    Ok(_) => {
                        let pkt_len = n as u64;
                        let mut dgram = Vec::with_capacity(flow_prefix.len() + n);
                        dgram.extend_from_slice(&flow_prefix);
                        dgram.extend_from_slice(pkt);

                        match conn.dgram_send_vec(dgram) {
                            Ok(()) => {
                                stats.tx_packets.fetch_add(1, Ordering::Relaxed);
                                stats.tx_bytes.fetch_add(pkt_len, Ordering::Relaxed);
                            }
                            Err(quiche::Error::InvalidState) => {
                                log::warn!("datagram send: peer doesn't support datagrams");
                            }
                            Err(quiche::Error::Done) => {
                                stats.dropped.fetch_add(1, Ordering::Relaxed);
                                log::trace!("datagram send queue full, dropping packet");
                            }
                            Err(e) => {
                                stats.dropped.fetch_add(1, Ordering::Relaxed);
                                log::debug!("datagram send error: {e}, generating ICMP");
                                if let Some(icmp_pkt) = icmp::compose_icmp_too_large(&tun_buf[..n], 1280) {
                                    write_tun(tun_writer, &icmp_pkt, &stats, &mut tun_write_failures).await?;
                                }
                            }
                        }
                    }
                    Err(e) => {
                        stats.dropped.fetch_add(1, Ordering::Relaxed);
                        log::trace!("dropping outgoing packet: {e}");
                    }
                }
            }

            // Read from QUIC socket
            result = socket.recv(&mut buf) => {
                let len = result?;
                let recv_info = quiche::RecvInfo {
                    to: local_addr,
                    from: tunnel_cfg.endpoint,
                };
                if let Err(e) = conn.recv(&mut buf[..len], recv_info) {
                    log::debug!("quic recv error: {e}");
                }
            }

            // Timeout handling
            () = tokio::time::sleep(timeout) => {
                conn.on_timeout();
            }

            // Continue a capped internal batch without waiting for a new
            // socket/TUN event. yield_now keeps this branch cooperative and
            // lets the other ready branches win fairly.
            () = tokio::task::yield_now(), if internal_work_pending => {}

            // quiche's SendInfo::at is a congestion-control pacing deadline.
            // Holding one packet until that deadline prevents packet bursts,
            // loss-recovery collapse, and a compute-only conn.send() loop.
            () = tokio::time::sleep(paced_send_delay), if paced_packet.is_some() => {
                let (packet, send_info) = paced_packet
                    .take()
                    .expect("paced packet must exist when its timer is enabled");
                if let Err(error) = socket.send_to(&packet, send_info.to).await {
                    log::warn!("paced UDP send error: {error}");
                }
            }
        }
        internal_work_pending = false;

        // Keep the campus/WAN UDP mapping alive and make a dead peer observable
        // even while no client packets are crossing the tunnel.
        if last_keepalive.elapsed() >= keepalive_interval {
            if let Err(error) = conn.send_ack_eliciting() {
                log::warn!("failed to schedule QUIC keepalive: {error}");
            }
            last_keepalive = Instant::now();
        }

        // After any event, drain all pending UDP packets from the socket.
        // This prevents stale ACKs and reduces unnecessary retransmissions
        // when the TUN or timeout branch wins the select.
        for index in 0..MAX_FORWARDING_BATCH {
            match socket.try_recv(&mut buf) {
                Ok(len) => {
                    let recv_info = quiche::RecvInfo {
                        to: local_addr,
                        from: tunnel_cfg.endpoint,
                    };
                    conn.recv(&mut buf[..len], recv_info).ok();
                    if forwarding_batch_limit_reached(index) {
                        internal_work_pending = true;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error.into()),
            }
        }

        // Process H3 events (capsules, etc.)
        for index in 0..MAX_FORWARDING_BATCH {
            match h3_conn.poll(&mut conn) {
                Ok(_) => {}
                Err(quiche::h3::Error::Done) => break,
                Err(e) => {
                    log::warn!("h3 poll error: {e}");
                    break;
                }
            }
            if forwarding_batch_limit_reached(index) {
                internal_work_pending = true;
            }
        }

        // Drain received datagrams -> TUN
        for index in 0..MAX_FORWARDING_BATCH {
            match conn.dgram_recv(&mut dgram_buf) {
                Ok(len) => {
                    if let Some(ip_payload) = parse_datagram(&dgram_buf[..len], flow_id) {
                        if packet::validate_incoming(ip_payload).is_ok() {
                            stats.rx_packets.fetch_add(1, Ordering::Relaxed);
                            stats
                                .rx_bytes
                                .fetch_add(ip_payload.len() as u64, Ordering::Relaxed);
                            write_tun(tun_writer, ip_payload, &stats, &mut tun_write_failures)
                                .await?;
                        }
                    }
                }
                Err(quiche::Error::Done) => break,
                Err(e) => {
                    log::debug!("dgram recv error: {e}");
                    break;
                }
            }
            if forwarding_batch_limit_reached(index) {
                internal_work_pending = true;
            }
        }

        // Flush an immediately-due QUIC batch. If quiche schedules a packet in
        // the future, retain that packet and resume output from the select loop
        // when its pacing deadline arrives.
        if paced_packet.is_none() {
            for index in 0..MAX_FORWARDING_BATCH {
                match conn.send(&mut out) {
                    Ok((write, send_info)) => {
                        if pacing_delay(send_info.at, Instant::now()).is_zero() {
                            if let Err(e) = socket.send_to(&out[..write], send_info.to).await {
                                log::warn!("UDP send error: {e}");
                                break;
                            }
                        } else {
                            paced_packet = Some((out[..write].to_vec(), send_info));
                            break;
                        }
                    }
                    Err(quiche::Error::Done) => break,
                    Err(e) => {
                        log::error!("quic send error: {e}");
                        bail!("quic send error: {e}");
                    }
                }
                if forwarding_batch_limit_reached(index) {
                    internal_work_pending = true;
                }
            }
        }

        // Stats are display-only; avoid querying the connection on every packet.
        if last_quic_stats_update.elapsed() >= Duration::from_secs(1) {
            let qs = conn.stats();
            stats.quic_lost.store(qs.lost as u64, Ordering::Relaxed);
            stats
                .quic_retrans
                .store(qs.retrans as u64, Ordering::Relaxed);
            last_quic_stats_update = Instant::now();
        }

        if conn.is_closed() {
            break Ok(());
        }
    };

    result
}

/// Parse an H3 datagram: `varint(flow_id)` + `varint(context_id)` + IP packet
/// Returns the IP payload slice if `flow_id` matches and `context_id` == 0.
fn parse_datagram(dgram: &[u8], expected_flow_id: u64) -> Option<&[u8]> {
    let mut b = octets::Octets::with_slice(dgram);

    let fid = b.get_varint().ok()?;
    if fid != expected_flow_id {
        return None;
    }

    let ctx_id = b.get_varint().ok()?;
    if ctx_id != 0 {
        return None;
    }

    let off = b.off();
    if off >= dgram.len() {
        return None;
    }

    Some(&dgram[off..])
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- parse_datagram tests ----

    fn encode_varint(val: u64) -> Vec<u8> {
        let mut tmp = [0u8; 8];
        let mut b = octets::OctetsMut::with_slice(&mut tmp);
        b.put_varint(val).unwrap();
        let len = b.off();
        tmp[..len].to_vec()
    }

    fn make_datagram(flow_id: u64, context_id: u64, payload: &[u8]) -> Vec<u8> {
        let mut dgram = Vec::new();
        dgram.extend_from_slice(&encode_varint(flow_id));
        dgram.extend_from_slice(&encode_varint(context_id));
        dgram.extend_from_slice(payload);
        dgram
    }

    #[test]
    fn parse_datagram_valid() {
        let payload = b"hello world";
        let dgram = make_datagram(0, 0, payload);
        let result = parse_datagram(&dgram, 0);
        assert_eq!(result, Some(payload.as_ref()));
    }

    #[test]
    fn parse_datagram_flow_id_mismatch() {
        let dgram = make_datagram(1, 0, b"data");
        assert_eq!(parse_datagram(&dgram, 0), None);
    }

    #[test]
    fn parse_datagram_nonzero_context() {
        let dgram = make_datagram(0, 1, b"data");
        assert_eq!(parse_datagram(&dgram, 0), None);
    }

    #[test]
    fn parse_datagram_empty_payload() {
        let dgram = make_datagram(0, 0, b"");
        // Empty payload means off == dgram.len(), should return None
        assert_eq!(parse_datagram(&dgram, 0), None);
    }

    #[test]
    fn parse_datagram_large_flow_id() {
        // flow_id that requires 4-byte varint encoding
        let flow_id = 16384;
        let payload = vec![0xABu8; 1300];
        let dgram = make_datagram(flow_id, 0, &payload);
        let result = parse_datagram(&dgram, flow_id);
        assert_eq!(result, Some(payload.as_ref()));
    }

    #[test]
    fn parse_datagram_truncated() {
        // Just a single byte - can't even decode flow_id
        let dgram = vec![0xFF];
        assert_eq!(parse_datagram(&dgram, 0), None);
    }

    // ---- format_bytes tests ----

    #[test]
    fn format_bytes_values() {
        assert_eq!(format_bytes(0), "0 B");
        assert_eq!(format_bytes(512), "512 B");
        assert_eq!(format_bytes(1023), "1023 B");
        assert_eq!(format_bytes(1024), "1.0 KiB");
        assert_eq!(format_bytes(1536), "1.5 KiB");
        assert_eq!(format_bytes(1_048_576), "1.0 MiB");
        assert_eq!(format_bytes(1_073_741_824), "1.0 GiB");
    }

    // ---- format_duration tests ----

    #[test]
    fn format_duration_values() {
        assert_eq!(format_duration(Duration::from_secs(0)), "0s");
        assert_eq!(format_duration(Duration::from_secs(59)), "59s");
        assert_eq!(format_duration(Duration::from_secs(60)), "1m 00s");
        assert_eq!(format_duration(Duration::from_secs(90)), "1m 30s");
        assert_eq!(format_duration(Duration::from_secs(3600)), "1h 00m 00s");
        assert_eq!(format_duration(Duration::from_secs(3661)), "1h 01m 01s");
    }

    #[test]
    fn event_loop_timeout_prevents_zero_duration_spin() {
        let keepalive = Duration::from_secs(30);
        assert_eq!(event_loop_timeout(None, keepalive), keepalive);
        assert_eq!(
            event_loop_timeout(Some(Duration::ZERO), keepalive),
            MIN_EVENT_LOOP_SLEEP
        );
        assert_eq!(
            event_loop_timeout(Some(Duration::from_millis(2)), keepalive),
            MIN_EVENT_LOOP_SLEEP
        );
        assert_eq!(
            event_loop_timeout(Some(Duration::from_millis(20)), keepalive),
            Duration::from_millis(20)
        );
        assert_eq!(
            event_loop_timeout(Some(Duration::from_secs(60)), keepalive),
            keepalive
        );
    }

    #[test]
    fn forwarding_batch_only_schedules_continuation_at_its_limit() {
        assert!(!forwarding_batch_limit_reached(0));
        assert!(!forwarding_batch_limit_reached(MAX_FORWARDING_BATCH - 2));
        assert!(forwarding_batch_limit_reached(MAX_FORWARDING_BATCH - 1));
    }

    // ---- TUN write failures ----

    struct FailingWriter;

    impl tokio::io::AsyncWrite for FailingWriter {
        fn poll_write(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
            _: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            std::task::Poll::Ready(Err(std::io::Error::other("TUN device gone")))
        }

        fn poll_flush(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }

        fn poll_shutdown(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn persistent_tun_write_failures_are_counted_then_end_the_session() {
        let stats = Stats::new();
        let mut failures = 0;
        for _ in 1..MAX_CONSECUTIVE_TUN_WRITE_FAILURES {
            assert!(
                write_tun(&mut FailingWriter, b"packet", &stats, &mut failures)
                    .await
                    .is_ok()
            );
        }
        assert!(
            write_tun(&mut FailingWriter, b"packet", &stats, &mut failures)
                .await
                .is_err()
        );
        assert_eq!(
            stats.dropped.load(Ordering::Relaxed),
            u64::from(MAX_CONSECUTIVE_TUN_WRITE_FAILURES)
        );
    }

    #[tokio::test]
    async fn a_successful_tun_write_resets_the_failure_count() {
        let stats = Stats::new();
        let mut failures = MAX_CONSECUTIVE_TUN_WRITE_FAILURES - 1;
        let mut sink: Vec<u8> = Vec::new();
        assert!(write_tun(&mut sink, b"packet", &stats, &mut failures)
            .await
            .is_ok());
        assert_eq!(failures, 0);
        assert_eq!(sink, b"packet");
        assert_eq!(stats.dropped.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn pacing_delay_waits_for_future_packets_without_rewaiting_past_packets() {
        let now = Instant::now();
        assert_eq!(pacing_delay(now, now), Duration::ZERO);
        assert_eq!(
            pacing_delay(now + Duration::from_millis(25), now),
            Duration::from_millis(25)
        );
        assert_eq!(
            pacing_delay(
                now.checked_sub(Duration::from_millis(25))
                    .expect("test instant should allow a 25 ms subtraction"),
                now
            ),
            Duration::ZERO
        );
    }
}

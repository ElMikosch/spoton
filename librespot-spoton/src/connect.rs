// SpotOn librespot-spoton/src/connect.rs
//
// Phase 5-01 implementation: --connect mode
//
// Provides:
//   - LMS struct: JSON-RPC event notifier (5 commands: start/change/stop/volume/seek)
//   - HttpStreamSink: wall-clock rate-limited PCM sink (S16LE) for HTTP streaming
//   - http_stream_server: hyper HTTP/1.1 server (/stream + /control/* endpoints)
//   - run_connect: orchestrator — Spirc + SoftMixer + event dispatch + HTTP server
//
// Architecture decisions:
//   D-01: HTTP streaming (not FIFO)
//   D-02: S16LE PCM as default
//   D-03: Dynamic port (bind :0, announce stream_port=N on stdout)
//   D-14: HTTP control endpoints (/control/pause|play|volume|seek|next|prev)
//   CON-11: Volume suppression on SessionConnected
//   CON-14: Nanosecond-accurate rate-limiting in HttpStreamSink::write()
//   CON-16: stream_port flushed to stdout immediately after println

use std::io::Write as IoWrite;
use std::sync::{Arc, atomic::{AtomicBool, AtomicU64, Ordering}};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full, StreamBody, combinators::BoxBody};
use hyper::{Method, Response, StatusCode};
use hyper::body::Frame;
use hyper::server::conn::http1 as HyperHttp1;
use hyper_util::rt::TokioIo;
use hyper_util::server::graceful::GracefulShutdown;
use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt as TokioStreamExt;

use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::Session;
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::{AudioFormat, PlayerConfig};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use librespot_playback::{NUM_CHANNELS, SAMPLE_RATE};

use librespot_discovery::DeviceType;

// -------------------------------------------------------------------------
// LMS struct — JSON-RPC notifier
// -------------------------------------------------------------------------

/// LMS-side notification target.
///
/// Sends JSON-RPC POST requests to LMS /jsonrpc.js when Spirc fires PlayerEvents.
/// Supports 6 command vocabulary: start, change, stop, volume, seek, resume.
///
/// `suppress_next_volume` is set on SessionConnected, then cleared on the first
/// VolumeChanged event — prevents the Spotify-stored device volume from clobbering
/// the LMS-side volume immediately after a Connect transfer (CON-11).
pub struct LMS {
    pub host_port: Option<String>,
    pub player_mac: Option<String>,
    pub auth: Option<String>,
    pub suppress_next_volume: Arc<AtomicBool>,
    /// Sender half of the flush watch-channel. Incremented on Seeked events to
    /// signal the HTTP relay task to drain pre-seek PCM bytes.
    pub flush_tx: Option<watch::Sender<u64>>,
    pub seek_gen: Arc<AtomicU64>,
    pub needs_position_sync: Arc<AtomicBool>,
    /// Nanoseconds-since-UNIX-EPOCH timestamp of the last None->Some TrackChanged (session start).
    /// Used by the grace-timer to suppress spurious Paused/Stopped within 2s of session start.
    /// Per D-03: only set on None->Some, never on Some->Some (track change within active session).
    pub last_session_start_ns: Arc<AtomicU64>,
    /// Set to true when Paused/Stopped fires after grace-timer check passes (real pause/stop).
    /// Cleared atomically by the Playing handler to detect resume-after-pause (D-01).
    pub was_paused: Arc<AtomicBool>,
}

impl LMS {
    pub fn new(
        host_port: Option<String>,
        player_mac: Option<String>,
        auth: Option<String>,
        flush_tx: Option<watch::Sender<u64>>,
    ) -> Self {
        Self {
            host_port,
            player_mac,
            // T-05-01: sanitize auth header — trim whitespace + remove embedded CR/LF
            // to prevent CRLF injection into hand-rolled HTTP/1.0 notify request.
            auth: auth.map(|raw| raw.trim().replace(['\r', '\n'], "").to_owned()),
            suppress_next_volume: Arc::new(AtomicBool::new(false)),
            flush_tx,
            seek_gen: Arc::new(AtomicU64::new(0)),
            needs_position_sync: Arc::new(AtomicBool::new(false)),
            last_session_start_ns: Arc::new(AtomicU64::new(0)),
            was_paused: Arc::new(AtomicBool::new(false)),
        }
    }

    /// True iff both host_port and player_mac are configured.
    /// Without either, notify() is a no-op.
    pub fn is_configured(&self) -> bool {
        self.host_port.is_some() && self.player_mac.is_some()
    }
}

impl Clone for LMS {
    fn clone(&self) -> Self {
        Self {
            host_port: self.host_port.clone(),
            player_mac: self.player_mac.clone(),
            auth: self.auth.clone(),
            suppress_next_volume: Arc::clone(&self.suppress_next_volume),
            // flush_tx is not Clone (watch::Sender doesn't implement Clone).
            // Only the original LMS instance fires flush signals.
            flush_tx: None,
            seek_gen: Arc::clone(&self.seek_gen),
            needs_position_sync: Arc::clone(&self.needs_position_sync),
            last_session_start_ns: Arc::clone(&self.last_session_start_ns),
            was_paused: Arc::clone(&self.was_paused),
        }
    }
}

// -------------------------------------------------------------------------
// PlayerEvent dispatcher
// -------------------------------------------------------------------------

impl LMS {
    /// Consume one PlayerEvent and emit zero-or-one spottyconnect JSON-RPC dispatches.
    ///
    /// `current_track` is the dispatch loop's cursor: base62 id of the last-seen
    /// Playing track. Mutated in place.
    ///
    /// Wire vocabulary (6 commands): start, change, stop, volume, seek, resume.
    /// "pause" is intentionally not emitted — Paused and Stopped collapse to "stop".
    pub async fn handle_player_event(
        &self,
        event: &PlayerEvent,
        current_track: &mut Option<String>,
    ) {
        if !self.is_configured() {
            return;
        }

        match event {
            // Playing fires for: track-start, un-pause, post-seek, buffer-underrun re-emit.
            // Emit `start` only on None→Some transition; same-id re-emits are no-ops;
            // different id is a `change`.
            // Exception: after TrackChanged sent `start`, the next same-id Playing carries
            // position_ms — send `seek` to sync LMS progress bar.
            PlayerEvent::Playing { track_id, position_ms, .. } => {
                let new_id = track_id.to_id().unwrap_or_default();
                log::debug!("[spoton] Playing: track_id={new_id}, position_ms={position_ms}");
                match current_track.as_deref() {
                    Some(prev) if prev == new_id.as_str() => {
                        // D-01: Check was_paused first — if set, this Playing is a resume.
                        // swap(false) clears the flag atomically to avoid double-resume.
                        if self.was_paused.swap(false, Ordering::AcqRel) {
                            let secs = f64::from(*position_ms) / 1000.0;
                            self.notify("resume", &new_id, &format!("{secs:.3}")).await;
                        } else if self.needs_position_sync.load(Ordering::Acquire) {
                            self.needs_position_sync.store(false, Ordering::Release);
                            let secs = f64::from(*position_ms) / 1000.0;
                            if secs > 1.0 {
                                self.notify("seek", &format!("{secs:.3}"), "").await;
                            }
                        }
                    }
                    Some(_) => {
                        self.needs_position_sync.store(false, Ordering::Release);
                        let prev = current_track.replace(new_id.clone()).unwrap_or_default();
                        self.notify("change", &new_id, &prev).await;
                    }
                    None => {
                        // TrackChanged is the authoritative "start" source.
                        // Only set cursor here as fallback (Playing without prior TrackChanged).
                        *current_track = Some(new_id.clone());
                    }
                }
            }

            // Both Paused and Stopped collapse into `stop`. Only fire if we had an active track.
            PlayerEvent::Paused { .. } | PlayerEvent::Stopped { .. } => {
                log::debug!("[spoton] Paused/Stopped (disc={:?}): current_track={:?}",
                    std::mem::discriminant(event), current_track.as_deref());
                // D-03: Grace-timer — suppress spurious Paused/Stopped within 2s of session start.
                // Spirc fires Paused (disc=5) immediately after TrackChanged at session start.
                // Without suppression, this sends a spurious "stop" to LMS, killing the session.
                let grace_ns: u64 = 2_000_000_000; // 2 seconds
                let last = self.last_session_start_ns.load(Ordering::Acquire);
                if last > 0 {
                    let now_ns = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_nanos() as u64;
                    let elapsed_ns = now_ns.saturating_sub(last);
                    if elapsed_ns < grace_ns {
                        log::debug!("[spoton] Paused/Stopped suppressed (grace timer, {}ms elapsed)",
                            elapsed_ns / 1_000_000);
                        return;
                    }
                }
                if current_track.is_some() {
                    // D-01: Set was_paused BEFORE notify("stop") so the Playing handler
                    // can detect resume-after-pause. Preserve current_track (no take())
                    // so the track context is available for resume detection.
                    self.was_paused.store(true, Ordering::Release);
                    self.notify("stop", "", "").await;
                }
            }

            // VolumeChanged: librespot reports 0..=65535; LMS speaks 0..=100.
            // Suppress the first event after SessionConnected (CON-11): that's a
            // Spotify-cloud echo, not a user action, and would clobber LMS-side volume.
            PlayerEvent::VolumeChanged { volume } => {
                log::debug!("[spoton] VolumeChanged: volume={volume}");
                if self.suppress_next_volume.swap(false, Ordering::Relaxed) {
                    // Suppress initial volume echo from Spotify on connect (CON-11)
                    return;
                }
                let pct = u32::from(*volume) * 100 / 65535;
                self.notify("volume", &pct.to_string(), "").await;
            }

            // Seeked: report position in seconds (3 decimals).
            // Also fire the flush watch-channel so the relay drains pre-seek PCM bytes.
            PlayerEvent::Seeked { position_ms, .. } => {
                log::debug!("[spoton] Seeked: position_ms={position_ms}");
                if current_track.is_some() {
                    let secs = f64::from(*position_ms) / 1000.0;
                    self.notify("seek", &format!("{secs:.3}"), "").await;
                }
                if let Some(tx) = &self.flush_tx {
                    let new_gen = self.seek_gen.fetch_add(1, Ordering::Release) + 1;
                    tx.send(new_gen).ok();
                }
            }

            // SessionConnected: arm the suppress flag (CON-11).
            // The next VolumeChanged will be the Spotify-stored volume echo — suppress it.
            PlayerEvent::SessionConnected { .. } => {
                log::debug!("[spoton] SessionConnected");
                self.suppress_next_volume.store(true, Ordering::Relaxed);
            }

            // TrackChanged: authoritative source for "start" and "change" notifications.
            // Playing only handles seek-sync for the same track.
            PlayerEvent::TrackChanged { audio_item } => {
                let new_id = audio_item.track_id.to_id().unwrap_or_default();
                log::debug!("[spoton] TrackChanged: track_id={new_id}");
                match current_track.as_deref() {
                    Some(prev) if prev == new_id.as_str() => { /* same track, no-op */ }
                    Some(_) => {
                        self.needs_position_sync.store(false, Ordering::Release);
                        let prev = current_track.replace(new_id.clone()).unwrap_or_default();
                        self.notify("change", &new_id, &prev).await;
                    }
                    None => {
                        // D-03: Session start — set grace timer to suppress spurious
                        // Paused/Stopped that Spirc fires immediately after TrackChanged.
                        // ONLY on None->Some (session start), never on Some->Some (track change).
                        let now_ns = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_nanos() as u64;
                        self.last_session_start_ns.store(now_ns, Ordering::Release);
                        log::debug!("[spoton] TrackChanged (session start): grace timer set");
                        self.needs_position_sync.store(true, Ordering::Release);
                        *current_track = Some(new_id.clone());
                        self.notify("start", &new_id, "").await;
                    }
                }
            }

            // All other events: no LMS equivalent.
            _ => {}
        }
    }

    /// POST a `spottyconnect <cmd> <p1> <p2>` JSON-RPC slim.request to LMS.
    ///
    /// Opens a fresh TCP connection per event (no keep-alive). Errors are
    /// swallowed with a warning — the daemon must never panic on LMS outage.
    /// If `auth` is set, adds `Authorization: Basic <creds>` header.
    async fn notify(&self, cmd: &str, p1: &str, p2: &str) {
        let host_port = match self.host_port.as_deref() {
            Some(h) => h,
            None => return,
        };
        let player_mac = match self.player_mac.as_deref() {
            Some(m) => m,
            None => return,
        };

        // Build variadic spottyconnect command array. Empty trailing params are dropped.
        let mut params: Vec<serde_json::Value> = Vec::with_capacity(4);
        params.push(json!("spottyconnect"));
        params.push(json!(cmd));
        if !p1.is_empty() {
            params.push(json!(p1));
        }
        if !p2.is_empty() {
            params.push(json!(p2));
        }
        let body = json!({
            "id": 1,
            "method": "slim.request",
            "params": [player_mac, params],
        })
        .to_string();

        let auth_header = match self.auth.as_deref() {
            Some(creds) => format!("Authorization: Basic {creds}\r\n"),
            None => String::new(),
        };

        let request = format!(
            "POST /jsonrpc.js HTTP/1.0\r\n\
             Host: {host_port}\r\n\
             Content-Type: application/json\r\n\
             Content-Length: {len}\r\n\
             {auth_header}\
             \r\n\
             {body}",
            len = body.len(),
        );

        match TcpStream::connect(host_port).await {
            Ok(mut stream) => {
                if let Err(_e) = stream.write_all(request.as_bytes()).await {
                }
            }
            Err(_e) => {
            }
        }
    }
}

// -------------------------------------------------------------------------
// HttpStreamSink
// -------------------------------------------------------------------------

/// Audio sink for --connect mode.
///
/// Unlike StdoutSink (which calls exit(0) in stop()), this sink's stop()
/// only resets counters — the process outlives individual track boundaries
/// for gapless Spotify Connect playback (CON Pitfall 1).
///
/// Rate-limiting follows nanosecond wall-clock math with an optional
/// buffer_latency_ns addend that compensates for LMS's audio buffer depth
/// (CON-14). Without compensation, Spirc reports the decoder's position
/// (ahead of audio output by LMS buffer latency), causing Spotify's progress
/// bar to drift ahead of what the user hears.
pub struct HttpStreamSink {
    pcm_tx: mpsc::Sender<Bytes>,
    /// Held for ownership — actual flush signals are sent by LMS::handle_player_event.
    #[allow(dead_code)]
    flush_tx: watch::Sender<u64>,
    began_at: Instant,
    frames_consumed: u64,
    buffer_latency_ns: u128,
}

impl HttpStreamSink {
    pub fn open(
        _device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
        flush_tx: watch::Sender<u64>,
        buffer_latency_ms: u64,
    ) -> Box<dyn Sink> {
        if format != AudioFormat::S16 {
            panic!(
                "HttpStreamSink: only AudioFormat::S16 supported, got {:?}",
                format
            );
        }
        Box::new(Self {
            pcm_tx,
            flush_tx,
            began_at: Instant::now(),
            frames_consumed: 0,
            buffer_latency_ns: u128::from(buffer_latency_ms) * 1_000_000u128,
        })
    }
}

impl Sink for HttpStreamSink {
    fn start(&mut self) -> SinkResult<()> {
        self.began_at = Instant::now();
        self.frames_consumed = 0;
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        // CRITICAL: do NOT call exit() here (Pitfall 1).
        // StdoutSink/pipe backend calls exit(0) — Connect daemon must not do this.
        // Reset counters only. Process outlives track boundaries.
        self.frames_consumed = 0;
        self.began_at = Instant::now();
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let AudioPacket::Samples(samples) = packet else {
            // Raw passthrough — not in scope for S16LE sink; skip.
            return Ok(());
        };

        // Convert f64 samples to S16LE bytes.
        let samples_s16 = converter.f64_to_s16(&samples);
        // SAFETY: i16 values are valid as two u8 bytes; ptr and len from valid Vec.
        let bytes: &[u8] = unsafe {
            std::slice::from_raw_parts(
                samples_s16.as_ptr().cast::<u8>(),
                samples_s16.len() * std::mem::size_of::<i16>(),
            )
        };

        // Wall-clock rate-limiter with buffer-latency compensation (CON-14).
        //
        // expected_ns = frames_consumed * 1e9 / SAMPLE_RATE + buffer_latency_ns
        //
        // Without rate-limiting: decoder races ahead of wall-clock, making Spotify
        // clients show nonsensical seek positions.
        //
        // With buffer_latency_ns > 0: decoder advances `buffer_latency_ms` ms slower
        // than wall-clock, so reported position matches actual audio output position.
        let frames_in_packet = (samples.len() / NUM_CHANNELS as usize) as u64;
        self.frames_consumed = self.frames_consumed.saturating_add(frames_in_packet);
        if self.frames_consumed % 1000 == 0 {
            log::trace!("[spoton] sink write: {} frames consumed", self.frames_consumed);
        }
        let expected_ns: u128 =
            u128::from(self.frames_consumed) * 1_000_000_000u128 / u128::from(SAMPLE_RATE)
            + self.buffer_latency_ns;
        let elapsed_ns: u128 = self.began_at.elapsed().as_nanos();

        if expected_ns > elapsed_ns {
            let park_ns = (expected_ns - elapsed_ns) as u64;
            std::thread::sleep(Duration::from_nanos(park_ns));
        }

        // Send PCM bytes over the channel to the HTTP stream server.
        // Player::new spawns a std::thread with its own tokio Runtime; Sink::write
        // runs within a tokio context. blocking_send would panic.
        // try_send with spin-retry: the channel has 256 slots (~1.5s of audio)
        // and a single consumer — contention is transient, rate-limiter keeps us
        // at real-time, so the channel is nearly always empty.
        let chunk = Bytes::copy_from_slice(bytes);
        loop {
            match self.pcm_tx.try_send(chunk.clone()) {
                Ok(()) => break,
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    return Err(SinkError::OnWrite(
                        "HTTP stream server shut down".into(),
                    ));
                }
            }
        }

        Ok(())
    }
}

// -------------------------------------------------------------------------
// http_stream_server
// -------------------------------------------------------------------------

/// HTTP server that streams PCM audio to LMS and accepts /control/* commands.
///
/// Endpoints:
///   GET  /stream         — S16LE PCM streaming body (CON-12, D-01)
///   POST /control/pause  — Spirc::pause()
///   POST /control/play   — Spirc::play()
///   POST /control/volume — Spirc::set_volume(vol_u16), body: {"volume": 0-100}
///   POST /control/seek   — Spirc::set_position_ms(ms), body: {"position_ms": N}
///   POST /control/next   — Spirc::next()
///   POST /control/prev   — Spirc::prev()
///
/// Guards:
///   - spirc_active=false → /stream returns 503 + Retry-After:2 (Pitfall 2 / T-05-06)
///   - relay_active=true  → /stream returns 503 (prevents split-PCM-stream, T-05-04/CR-01)
///   - Volume clamped to 0..=100, converted to 0..=65535 range (T-05-02)
///   - position_ms validated as u32 (T-05-03)
pub async fn http_stream_server(
    listener: TcpListener,
    pcm_rx: mpsc::Receiver<Bytes>,
    spirc_active: Arc<AtomicBool>,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
    flush_rx: watch::Receiver<u64>,
    spirc_handle: Arc<std::sync::Mutex<Option<Spirc>>>,
) {
    use std::sync::Mutex;

    let graceful = GracefulShutdown::new();
    let mut shutdown_rx = std::pin::pin!(shutdown_rx);

    // Wrap pcm_rx in Arc<Mutex> so relay task can acquire it exclusively without Clone.
    let pcm_rx = Arc::new(Mutex::new(pcm_rx));
    // Wrap flush_rx in Arc<Mutex> so it can be shared across connections.
    let flush_rx = Arc::new(Mutex::new(flush_rx));
    // CR-01: guard against concurrent relay tasks that would split the PCM stream.
    let relay_active = Arc::new(AtomicBool::new(false));

    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                let (stream, _addr) = match accept_result {
                    Ok(pair) => pair,
                    Err(_) => continue,
                };

                let spirc_active = Arc::clone(&spirc_active);
                let pcm_rx = Arc::clone(&pcm_rx);
                let flush_rx = Arc::clone(&flush_rx);
                let relay_active = Arc::clone(&relay_active);
                let spirc_handle = Arc::clone(&spirc_handle);

                let svc = hyper::service::service_fn(move |req: hyper::Request<hyper::body::Incoming>| {
                    let spirc_active = Arc::clone(&spirc_active);
                    let pcm_rx = Arc::clone(&pcm_rx);
                    let flush_rx = Arc::clone(&flush_rx);
                    let relay_active = Arc::clone(&relay_active);
                    let spirc_handle = Arc::clone(&spirc_handle);
                    async move {
                        let path = req.uri().path().to_owned();
                        let method = req.method().clone();

                        // ---- GET /stream ----
                        if method == Method::GET && path == "/stream" {
                            log::debug!("[spoton] /stream: GET request received");

                            // Pitfall 2 / T-05-06: wait up to 5s for Spirc to become active.
                            // In sync-group proxy mode, LMS connects before Spotify session
                            // is fully established.
                            let mut waited = 0u32;
                            while !spirc_active.load(Ordering::Acquire) && waited < 50 {
                                tokio::time::sleep(Duration::from_millis(100)).await;
                                waited += 1;
                            }
                            if !spirc_active.load(Ordering::Acquire) {
                                let body = Full::new(Bytes::new())
                                    .map_err(|e| match e {})
                                    .boxed();
                                let resp = Response::builder()
                                    .status(StatusCode::SERVICE_UNAVAILABLE)
                                    .header("Retry-After", "2")
                                    .header("Content-Length", "0")
                                    .body(body)
                                    .expect("static 503 spirc-inactive builder");
                                return Ok::<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error>(resp);
                            }

                            // CR-01 / T-05-04: reject concurrent relay attempts.
                            if relay_active.swap(true, Ordering::AcqRel) {
                                let body = Full::new(Bytes::new())
                                    .map_err(|e| match e {})
                                    .boxed();
                                let resp = Response::builder()
                                    .status(StatusCode::SERVICE_UNAVAILABLE)
                                    .header("Retry-After", "1")
                                    .header("Content-Length", "0")
                                    .body(body)
                                    .expect("static 503 relay-busy builder");
                                return Ok::<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error>(resp);
                            }

                            // Drain stale pre-seek audio from the channel (D-03).
                            {
                                let mut rx = pcm_rx.lock().unwrap();
                                let mut drained = 0u64;
                                while rx.try_recv().is_ok() { drained += 1; }
                                log::debug!("[spoton] /stream: relay starting, drained {} stale chunks", drained);
                            }

                            // Per-connection relay channel (64 frames capacity).
                            let (conn_tx, conn_rx) = mpsc::channel::<Bytes>(64);

                            let pcm_rx_clone = Arc::clone(&pcm_rx);
                            let flush_rx_clone = Arc::clone(&flush_rx);
                            let relay_active_clone = Arc::clone(&relay_active);
                            tokio::spawn(async move {
                                // Initialise last_seen_gen to avoid draining on first iteration.
                                let mut last_seen_gen: u64 = {
                                    let rx = flush_rx_clone.lock().unwrap();
                                    let val: u64 = *rx.borrow();
                                    drop(rx);
                                    val
                                };

                                loop {
                                    // Seek-flush drain: poll before each read.
                                    let flush_pending = {
                                        let rx = flush_rx_clone.lock().unwrap();
                                        let changed = rx.has_changed().unwrap_or(false);
                                        drop(rx);
                                        changed
                                    };
                                    if flush_pending {
                                        let new_gen = {
                                            let mut rx = flush_rx_clone.lock().unwrap();
                                            let val: u64 = *rx.borrow_and_update();
                                            drop(rx);
                                            val
                                        };
                                        if new_gen > last_seen_gen {
                                            let mut count: u64 = 0;
                                            let mut rx = pcm_rx_clone.lock().unwrap();
                                            while rx.try_recv().is_ok() {
                                                count += 1;
                                            }
                                            last_seen_gen = new_gen;
                                            let _ = count; // suppress warning
                                        }
                                    }

                                    // Normal relay — poll once, release lock before await.
                                    let chunk = {
                                        let mut rx = pcm_rx_clone.lock().unwrap();
                                        rx.try_recv().ok()
                                    };
                                    match chunk {
                                        Some(bytes) => {
                                            if conn_tx.send(bytes).await.is_err() {
                                                log::debug!("[spoton] /stream: relay client disconnected");
                                                break;
                                            }
                                        }
                                        None => {
                                            // No data available; sleep 1ms to avoid hot-loop.
                                            tokio::time::sleep(Duration::from_millis(1)).await;
                                        }
                                    }
                                }
                                // Clear relay-active flag so next LMS reconnect can start.
                                relay_active_clone.store(false, Ordering::Release);
                            });

                            let stream = TokioStreamExt::map(ReceiverStream::new(conn_rx), |chunk| {
                                Ok::<Frame<Bytes>, hyper::Error>(Frame::data(chunk))
                            });
                            let body = BodyExt::boxed(StreamBody::new(stream));

                            // Always respond with 200 OK. HTTP/1.0 clients (LMS proxy)
                            // do not support 206 Partial Content.
                            let resp = Response::builder()
                                .status(StatusCode::OK)
                                .header("Content-Type", "audio/L16;rate=44100;channels=2")
                                .body(body)
                                .expect("stream response builder");
                            return Ok::<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error>(resp);
                        }

                        // ---- POST /control/* — Spirc commands ----
                        if method == Method::POST && path.starts_with("/control/") {
                            let cmd = &path["/control/".len()..];

                            // Read body for volume and seek commands.
                            let body_bytes = {
                                use http_body_util::BodyExt as _;
                                match req.into_body().collect().await {
                                    Ok(collected) => collected.to_bytes(),
                                    Err(_) => Bytes::new(),
                                }
                            };

                            let spirc_guard = spirc_handle.lock().unwrap();
                            let result = if let Some(spirc) = spirc_guard.as_ref() {
                                match cmd {
                                    "pause" => spirc.pause().ok(),
                                    "play" => spirc.play().ok(),
                                    "next" => spirc.next().ok(),
                                    "prev" => spirc.prev().ok(),
                                    "volume" => {
                                        // T-05-02: parse volume as u32, clamp 0..=100,
                                        // convert to 0..=65535 range.
                                        if let Ok(json_val) = serde_json::from_slice::<serde_json::Value>(&body_bytes) {
                                            if let Some(vol) = json_val.get("volume").and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))) {
                                                let vol_clamped = vol.min(100) as u32;
                                                let vol_u16 = (vol_clamped * 65535 / 100) as u16;
                                                spirc.set_volume(vol_u16).ok()
                                            } else {
                                                None
                                            }
                                        } else {
                                            None
                                        }
                                    }
                                    "seek" => {
                                        // T-05-03: parse position_ms as u64, reject if >u32::MAX.
                                        if let Ok(json_val) = serde_json::from_slice::<serde_json::Value>(&body_bytes) {
                                            if let Some(pos) = json_val.get("position_ms").and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))) {
                                                if let Ok(pos_u32) = u32::try_from(pos) {
                                                    spirc.set_position_ms(pos_u32).ok()
                                                } else {
                                                    None
                                                }
                                            } else {
                                                None
                                            }
                                        } else {
                                            None
                                        }
                                    }
                                    _ => None,
                                }
                            } else {
                                None
                            };
                            drop(spirc_guard);

                            let status = if result.is_some() || cmd == "pause" || cmd == "play" || cmd == "next" || cmd == "prev" || cmd == "volume" || cmd == "seek" {
                                // Return 204 No Content for valid control commands
                                // (even if Spirc returned Err — daemon not active is non-fatal)
                                // D-03: volume and seek are known endpoints — always 204, not 404
                                // on body parse failures (e.g. missing JSON body from Perl side).
                                StatusCode::NO_CONTENT
                            } else {
                                StatusCode::NOT_FOUND
                            };

                            let body = Full::new(Bytes::new())
                                .map_err(|e| match e {})
                                .boxed();
                            let resp = Response::builder()
                                .status(status)
                                .header("Content-Length", "0")
                                .body(body)
                                .expect("control response builder");
                            return Ok::<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error>(resp);
                        }

                        // ---- 404 for everything else ----
                        let body = Full::new(Bytes::new())
                            .map_err(|e| match e {})
                            .boxed();
                        let resp = Response::builder()
                            .status(StatusCode::NOT_FOUND)
                            .header("Content-Length", "0")
                            .body(body)
                            .expect("static 404 builder");
                        Ok::<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error>(resp)
                    }
                });

                // Use hyper http1::Builder::serve_connection — returns owned Connection<I, S>
                // with no lifetime parameter, compatible with graceful.watch + tokio::spawn.
                let io = TokioIo::new(stream);
                let conn = HyperHttp1::Builder::new().serve_connection(io, svc);
                let fut = graceful.watch(conn);
                tokio::spawn(async move {
                    let _ = fut.await;
                });
            }
            _ = &mut shutdown_rx => {
                break;
            }
        }
    }

    graceful.shutdown().await;
}

// -------------------------------------------------------------------------
// run_connect — main orchestrator
// -------------------------------------------------------------------------

/// Run Spotify Connect mode: Spirc event loop + HTTP streaming server.
///
/// Startup sequence:
///   1. Load Cache + Credentials
///   2. Create PCM channel (mpsc 256) + flush watch-channel
///   3. Create SoftMixer (Pitfall 8 — required for volume control)
///   4. Create Player with HttpStreamSink
///   5. Bind TcpListener on :0 (D-03 dynamic port)
///   6. println!("stream_port=N") + stdout().flush() (Pitfall 3, CON-16)
///   7. Spawn http_stream_server
///   8. Spawn LMS event dispatcher
///   9. Spawn spirc_active watcher (set true ONLY on SessionConnected — Pitfall 2)
///   10. Spirc::new() + store in Arc<Mutex<Option<Spirc>>>
///   11. Main event loop: spirc_task, ctrl_c, reconnect
pub async fn run_connect(
    cache_dir: &str,
    device_name: &str,
    player_mac: Option<&str>,
    lms_host_port: Option<&str>,
    lms_auth: Option<&str>,
    disable_discovery: bool,
    buffer_latency_ms: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Cache + Credentials
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;
    let credentials = match cache.credentials() {
        Some(c) => c,
        None => {
            return Err(format!(
                "No cached credentials in '{}'. Run --authenticate or --discover-once first.",
                cache_dir
            ).into());
        }
    };

    // 2. PCM channel + flush watch-channel
    let (pcm_tx, pcm_rx) = mpsc::channel::<Bytes>(256);
    let (flush_tx, flush_rx) = watch::channel::<u64>(0);
    let flush_tx_for_lms = flush_tx.clone();

    // 3. SoftMixer — required for Spirc volume control (Pitfall 8)
    let mixer_fn = librespot_playback::mixer::find(Some(SoftMixer::NAME))
        .ok_or("SoftMixer not found")?;
    let mixer: Arc<dyn Mixer> = mixer_fn(MixerConfig::default())?;
    let soft_volume = mixer.get_soft_volume();

    // 4. Session (connect later via Spirc::new)
    let session_config = SessionConfig::default();
    let session = Session::new(session_config.clone(), Some(cache.clone()));

    // spirc_active: set to true ONLY on SessionConnected (Pitfall 2 / T-05-06)
    let spirc_active = Arc::new(AtomicBool::new(false));

    // 5. Player with HttpStreamSink
    let pcm_tx_clone = pcm_tx.clone();
    let flush_tx_for_sink = flush_tx.clone();
    let buffer_latency_ms_copy = buffer_latency_ms;
    let player = Player::new(
        PlayerConfig::default(),
        session.clone(),
        soft_volume,
        move || {
            HttpStreamSink::open(
                None,
                AudioFormat::S16,
                pcm_tx_clone,
                flush_tx_for_sink,
                buffer_latency_ms_copy,
            )
        },
    );

    // 6. Bind TcpListener on :0, announce stream_port (D-03, CON-16, Pitfall 3)
    let listener = TcpListener::bind("0.0.0.0:0").await?;
    let port = listener.local_addr()?.port();
    println!("stream_port={}", port);
    // Explicit flush — stdout is pipe-buffered; without this Perl IO::Select times out.
    std::io::stdout().flush()?;

    // Spirc handle: shared between http_stream_server and main loop
    let spirc_handle: Arc<std::sync::Mutex<Option<Spirc>>> =
        Arc::new(std::sync::Mutex::new(None));

    // 7. Spawn http_stream_server
    let (http_shutdown_tx, http_shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let spirc_active_for_http = Arc::clone(&spirc_active);
    let spirc_handle_for_http = Arc::clone(&spirc_handle);
    let http_handle = tokio::spawn(http_stream_server(
        listener,
        pcm_rx,
        spirc_active_for_http,
        http_shutdown_rx,
        flush_rx,
        spirc_handle_for_http,
    ));

    // 8. Spawn LMS event dispatcher
    let lms = LMS::new(
        lms_host_port.map(String::from),
        player_mac.map(String::from),
        lms_auth.map(String::from),
        Some(flush_tx_for_lms),
    );
    if lms.is_configured() {
        let mut event_chan = player.get_player_event_channel();
        tokio::spawn(async move {
            let mut current_track: Option<String> = None;
            while let Some(event) = event_chan.recv().await {
                lms.handle_player_event(&event, &mut current_track).await;
            }
        });
    }

    // 9. Spawn spirc_active watcher — set true on session or playback events.
    // SessionConnected may not fire reliably in all librespot versions;
    // Playing/TrackChanged are definitive proof that Spirc is active.
    {
        let mut session_event_chan = player.get_player_event_channel();
        let sa = Arc::clone(&spirc_active);
        tokio::spawn(async move {
            while let Some(event) = session_event_chan.recv().await {
                if matches!(event,
                    PlayerEvent::SessionConnected { .. } |
                    PlayerEvent::Playing { .. } |
                    PlayerEvent::TrackChanged { .. }
                ) {
                    sa.store(true, Ordering::SeqCst);
                }
            }
        });
    }

    // 10. ConnectConfig + Spirc::new()
    // Note: librespot-connect 0.8.0 ConnectConfig differs from Spotty-NG:
    //   - No `autoplay` field
    //   - `has_volume_ctrl` renamed to `disable_volume` (inverted)
    //   - `initial_volume` is u16 (not Option)
    let connect_config = ConnectConfig {
        name: device_name.to_string(),
        device_type: DeviceType::Speaker,
        initial_volume: u16::MAX / 2, // 50%
        disable_volume: false,        // has volume control
        ..ConnectConfig::default()
    };

    // Spirc::new() calls session.connect() internally.
    // Pass cloned credentials; cache already written in run_authenticate/run_discover_once.
    let (spirc, spirc_task) = Spirc::new(
        connect_config,
        session.clone(),
        credentials.clone(),
        player.clone(),
        mixer,
    )
    .await?;

    // Store Spirc in shared handle so http_stream_server can dispatch control commands (D-14).
    {
        let mut guard = spirc_handle.lock().unwrap();
        *guard = Some(spirc);
    }

    // 11. Main event loop
    let mut reconnect_times: Vec<std::time::Instant> = Vec::new();
    let mut last_credentials: Option<Credentials> = Some(credentials);
    let mut connecting = false;
    let mut current_session = session;
    let mut current_spirc_task: Option<tokio::task::JoinHandle<()>> =
        Some(tokio::spawn(spirc_task));

    // Optional discovery for reconnect (respects --disable-discovery flag)
    let mut discovery = if disable_discovery {
        None
    } else {
        // Use cache_dir hash as stable device_id
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        cache_dir.hash(&mut hasher);
        let device_id = format!("{:016x}", hasher.finish());
        const KEYMASTER_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
        match librespot_discovery::Discovery::builder(device_id, KEYMASTER_CLIENT_ID.to_string())
            .name(device_name.to_string())
            .device_type(DeviceType::Speaker)
            .launch()
        {
            Ok(d) => Some(d),
            Err(_) => None,
        }
    };

    loop {
        tokio::select! {
            // New credentials from ZeroConf Discovery (optional reconnect path)
            new_creds = async {
                match discovery.as_mut() {
                    Some(d) => futures_util::StreamExt::next(d).await,
                    None => None,
                }
            }, if discovery.is_some() => {
                if let Some(creds) = new_creds {
                    last_credentials = Some(creds);
                    // Shutdown existing Spirc
                    {
                        let mut guard = spirc_handle.lock().unwrap();
                        if let Some(ref s) = *guard {
                            let _ = s.shutdown();
                        }
                        *guard = None;
                    }
                    spirc_active.store(false, Ordering::SeqCst);
                    if !current_session.is_invalid() {
                        current_session.shutdown();
                    }
                    connecting = true;
                }
            },

            // Reconnect with new credentials
            _ = async {}, if connecting && last_credentials.is_some() => {
                if current_session.is_invalid() {
                    let cache2 = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None).ok();
                    current_session = Session::new(session_config.clone(), cache2);
                    player.set_session(current_session.clone());
                }

                let new_connect_config = ConnectConfig {
                    name: device_name.to_string(),
                    device_type: DeviceType::Speaker,
                    initial_volume: u16::MAX / 2,
                    disable_volume: false,
                    ..ConnectConfig::default()
                };

                match Spirc::new(
                    new_connect_config,
                    current_session.clone(),
                    last_credentials.clone().unwrap(),
                    player.clone(),
                    mixer_fn(MixerConfig::default()).unwrap_or_else(|_| panic!("mixer")),
                ).await {
                    Ok((new_spirc, new_task)) => {
                        {
                            let mut guard = spirc_handle.lock().unwrap();
                            *guard = Some(new_spirc);
                        }
                        current_spirc_task = Some(tokio::spawn(new_task));
                        connecting = false;
                    }
                    Err(e) => {
                        eprintln!("Spirc reconnect failed: {e}");
                        process::exit(1);
                    }
                }
            },

            // Spirc task completed unexpectedly — attempt reconnect with backoff
            result = async {
                if let Some(task) = current_spirc_task.as_mut() {
                    task.await
                } else {
                    std::future::pending().await
                }
            }, if current_spirc_task.is_some() && !connecting => {
                current_spirc_task = None;
                spirc_active.store(false, Ordering::SeqCst);
                let _ = result;

                // Rate-limit reconnects: allow at most 5 in 60s
                const RECONNECT_RATE_LIMIT: usize = 5;
                let rate_window = Duration::from_secs(60);
                reconnect_times.retain(|&t: &std::time::Instant| t.elapsed() < rate_window);
                if last_credentials.is_some() && reconnect_times.len() < RECONNECT_RATE_LIMIT {
                    reconnect_times.push(std::time::Instant::now());
                    if !current_session.is_invalid() {
                        current_session.shutdown();
                    }
                    connecting = true;
                } else {
                    eprintln!("Spirc shut down too often. Not reconnecting.");
                    break;
                }
            },

            // Player died unexpectedly
            _ = async {}, if player.is_invalid() => {
                eprintln!("Player shut down unexpectedly");
                break;
            },

            // Ctrl+C / SIGINT
            _ = tokio::signal::ctrl_c() => {
                break;
            },

            else => break,
        }
    }

    // Graceful shutdown
    {
        let mut guard = spirc_handle.lock().unwrap();
        if let Some(ref s) = *guard {
            let _ = s.shutdown();
        }
        *guard = None;
    }
    spirc_active.store(false, Ordering::SeqCst);

    // Signal HTTP server to stop
    let _ = http_shutdown_tx.send(());
    let _ = http_handle.await;

    Ok(())
}

// Allow process::exit in the reconnect error path
use std::process;

// browse.rs — SpotOn Browse daemon
//
// Responsibilities:
//   - run_browse(): entry point — Session setup, port bind, announce, serve
//   - browse_http_server(): hyper HTTP/1.1 server (GET /track/{spotify_id})
//   - BrowseHttpSink: unbuffered PCM sink (NO rate-limiting — no Spirc position sync)
//   - serve_track_request(): per-request handler — load Player, stream PCM, close on EOF/Unavailable
//
// Key differences from connect.rs:
//   - NO Spirc (no Connect crate) — daemon is invisible to Spotify app (Pitfall 1)
//   - NO rate-limiting in BrowseHttpSink (Pitfall 3)
//   - NO flush watch-channel — seek is via ?start_position=N query param
//   - Per-request Player instances for concurrent requests (D-04, Pitfall 2)
//   - HTTP endpoint: GET /track/{id} instead of GET /stream

use std::convert::Infallible;
use std::io::Write as IoWrite;
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full, StreamBody, combinators::BoxBody};
use hyper::body::Frame;
use hyper::{Method, Response, StatusCode};
use hyper::server::conn::http1 as HyperHttp1;
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt as TokioStreamExt;

use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::{Session, SpotifyUri};
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::{AudioFormat, PlayerConfig};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player, PlayerEvent};

// -------------------------------------------------------------------------
// BrowseHttpSink — unbuffered PCM sender, no rate-limiting
// -------------------------------------------------------------------------

/// Audio sink for --browse mode.
///
/// Unlike HttpStreamSink in connect.rs, this sink does NOT rate-limit PCM delivery.
/// Browse mode has no Spirc position sync — PCM should be sent as fast as librespot
/// produces it (Pitfall 3). LMS controls playback timing via its own audio buffer.
///
/// stop() is a no-op — daemon outlives track boundaries (same as HttpStreamSink,
/// but without the frame counter reset since there is nothing to reset here).
pub struct BrowseHttpSink {
    pcm_tx: mpsc::Sender<Bytes>,
}

impl BrowseHttpSink {
    /// Construct a new BrowseHttpSink.
    ///
    /// Only AudioFormat::S16 is supported — panics on any other format.
    /// The factory closure passed to Player::new() captures `pcm_tx` by clone.
    pub fn open(
        _device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
    ) -> Box<dyn Sink> {
        if format != AudioFormat::S16 {
            panic!(
                "BrowseHttpSink: only AudioFormat::S16 supported, got {:?}",
                format
            );
        }
        Box::new(Self { pcm_tx })
    }
}

impl Sink for BrowseHttpSink {
    fn start(&mut self) -> SinkResult<()> {
        // No state to initialise — Browse daemon is stateless per-packet.
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        // CRITICAL: do NOT call exit() here (same as HttpStreamSink Pitfall 1).
        // Browse daemon outlives track boundaries — stop() is called between tracks,
        // NOT when the process should exit.
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

        let chunk = Bytes::copy_from_slice(bytes);

        // try_send loop: channel has 256 slots (~1.5s of audio).
        // Spin on Full (backpressure from LMS reading PCM at real-time speed).
        // Return SinkError on Closed (HTTP client disconnected, LMS gave up).
        // NOTE: No wall-clock sleep or frame accounting — Browse has no Spirc position sync.
        loop {
            match self.pcm_tx.try_send(chunk.clone()) {
                Ok(()) => break,
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    return Err(SinkError::OnWrite(
                        "Browse HTTP connection closed".into(),
                    ));
                }
            }
        }

        Ok(())
    }
}

// -------------------------------------------------------------------------
// run_browse — entry point
// -------------------------------------------------------------------------

/// Run the Browse daemon: load credentials, connect session, bind port, serve HTTP.
///
/// Contract:
///   stdout line 1: "browse_port=N"   (N = dynamically assigned TCP port)
///   stdout is flushed immediately (Perl IO::Select requires this — Pitfall 5)
///
/// Session is persistent — audio keys are cached across track boundaries.
/// Daemon runs until killed by DaemonManager.
pub async fn run_browse(
    cache_dir: &str,
    player_mac: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Suppress unused warning — player_mac is available for future diagnostics.
    let _ = player_mac;

    // 1. Cache + Credentials
    //    Third arg (audio_path = Some(cache_dir)) enables librespot's audio key cache.
    //    This is the primary benefit of the persistent session: audio keys fetched for
    //    track N remain cached when track N+1 is requested, eliminating per-track AP round-trips.
    let cache = Cache::new(Some(cache_dir), None::<&str>, Some(cache_dir), None)?;

    let credentials = match cache.credentials() {
        Some(c) => c,
        None => {
            return Err(format!(
                "No cached credentials in '{}'. Run --discover-once first.",
                cache_dir
            )
            .into());
        }
    };

    // 2. Session — NO Spirc, NO Connect crate import (Pitfall 1: browse daemon MUST NOT
    //    appear as a device in the Spotify app). This is identical to run_single_track().
    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));
    session.connect(credentials, false).await?;

    // 3. Bind dynamic port, announce browse_port=N on stdout.
    //    The Perl Daemon.pm reads this line synchronously with IO::Select (5s timeout).
    //    Flush is CRITICAL — Perl IO::Select will time out if stdout is not flushed (Pitfall 5).
    let listener = TcpListener::bind("0.0.0.0:0").await?;
    let port = listener.local_addr()?.port();
    println!("browse_port={}", port);
    std::io::stdout().flush()?;

    // 4. Serve HTTP track requests until process is killed.
    browse_http_server(listener, session).await
}

// -------------------------------------------------------------------------
// browse_http_server — hyper HTTP/1.1 accept loop
// -------------------------------------------------------------------------

/// Accept loop for Browse HTTP server.
///
/// Route: GET /track/{spotify_id}
///   - track_id must match [A-Za-z0-9]+ (T-28-01: Tampering mitigation)
///   - Valid request: spawn tokio task → serve_track_request()
///   - Invalid track ID format: 400
///   - Invalid path or method: 404
///
/// Each request is served in an independent tokio task, supporting concurrent
/// current-track and prefetch-track streaming (D-04).
async fn browse_http_server(
    listener: TcpListener,
    session: Session,
) -> Result<(), Box<dyn std::error::Error>> {
    loop {
        let (stream, _addr) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                log::warn!("[spoton/browse] accept error: {}", e);
                continue;
            }
        };

        let session_clone = session.clone();

        let svc = hyper::service::service_fn(move |req: hyper::Request<hyper::body::Incoming>| {
            let session = session_clone.clone();
            async move {
                handle_request(req, session).await
            }
        });

        let io = TokioIo::new(stream);
        tokio::spawn(async move {
            if let Err(e) = HyperHttp1::Builder::new().serve_connection(io, svc).await {
                // Connection errors are normal (client disconnect, LMS advancing tracks).
                log::debug!("[spoton/browse] connection error: {}", e);
            }
        });
    }
}

/// Route a single HTTP request.
///
/// Extracts track ID from `GET /track/{id}` path.
/// Returns 400 for invalid track ID format, 404 for anything else.
async fn handle_request(
    req: hyper::Request<hyper::body::Incoming>,
    session: Session,
) -> Result<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error> {
    let path = req.uri().path().to_owned();
    let method = req.method().clone();

    // Only GET is supported.
    if method != Method::GET {
        return Ok(empty_response(StatusCode::METHOD_NOT_ALLOWED));
    }

    // Route: GET /track/{spotify_id}
    // Security (T-28-01): validate track ID as [A-Za-z0-9]+ before building SpotifyUri.
    if let Some(track_id) = path.strip_prefix("/track/") {
        // Input validation: track ID must be non-empty and alphanumeric only.
        if track_id.is_empty() || !track_id.chars().all(|c| c.is_ascii_alphanumeric()) {
            log::warn!("[spoton/browse] rejected invalid track ID: {:?}", track_id);
            return Ok(empty_response(StatusCode::BAD_REQUEST));
        }

        // Parse optional ?start_position=N query parameter (seconds as f64).
        let start_position_ms: u32 = req.uri().query()
            .and_then(|q| {
                q.split('&')
                    .find(|kv| kv.starts_with("start_position="))
                    .and_then(|kv| kv.strip_prefix("start_position="))
                    .and_then(|v| v.parse::<f64>().ok())
            })
            .map(|secs| {
                if secs < 0.0 { 0u32 } else { (secs * 1000.0).min(u32::MAX as f64) as u32 }
            })
            .unwrap_or(0);

        let track_id = track_id.to_owned();

        log::debug!(
            "[spoton/browse] GET /track/{} start_position_ms={}",
            track_id,
            start_position_ms
        );

        // Per-request mpsc channel carries decoded PCM from BrowseHttpSink to the response body.
        let (pcm_tx, pcm_rx) = mpsc::channel::<Bytes>(256);

        // Spawn track handler — runs the librespot Player and drives PCM into pcm_tx.
        // On Unavailable: drops pcm_tx, causing response body to close; we return 404 via
        // a separate status channel.
        let (status_tx, mut status_rx) = tokio::sync::oneshot::channel::<StatusCode>();

        tokio::spawn(async move {
            let status = serve_track_request(&track_id, session, pcm_tx, start_position_ms).await;
            let _ = status_tx.send(status);
        });

        // Wait briefly for the track handler to determine if the track is available.
        // PlayerEvent::Unavailable fires before any PCM; on a typical available track
        // the handler sends PlayerEvent::Loading / Playing quickly and we proceed.
        // Strategy: poll the status channel with a short timeout — if unavailable fires
        // quickly we can return 404 before sending response headers.
        //
        // If track is available the status_tx is never sent (handler blocks in PCM relay),
        // so we proceed with streaming. If status_tx fires before the timeout, return 404.
        let early_status = tokio::time::timeout(
            Duration::from_millis(500),
            &mut status_rx,
        ).await;

        if let Ok(Ok(StatusCode::NOT_FOUND)) = early_status {
            log::info!("[spoton/browse] track unavailable — returning 404");
            return Ok(empty_response(StatusCode::NOT_FOUND));
        }

        // Build streaming response: ReceiverStream -> StreamBody -> BoxBody.
        // Content-Type matches connect.rs (S16LE PCM at 44100 Hz stereo).
        let stream = TokioStreamExt::map(
            ReceiverStream::new(pcm_rx),
            |chunk| Ok::<Frame<Bytes>, hyper::Error>(Frame::data(chunk)),
        );
        let body = BodyExt::boxed(StreamBody::new(stream));

        let resp = Response::builder()
            .status(StatusCode::OK)
            .header("Content-Type", "audio/L16;rate=44100;channels=2")
            .body(body)
            .expect("browse stream response builder");

        return Ok(resp);
    }

    // All other paths: 404.
    Ok(empty_response(StatusCode::NOT_FOUND))
}

/// Build an empty response body (for error responses).
pub fn empty_response(status: StatusCode) -> Response<BoxBody<Bytes, hyper::Error>> {
    let body = Full::new(Bytes::new())
        .map_err(|e: Infallible| match e {})
        .boxed();
    Response::builder()
        .status(status)
        .header("Content-Length", "0")
        .body(body)
        .expect("empty response builder")
}

// -------------------------------------------------------------------------
// serve_track_request — per-request track handler
// -------------------------------------------------------------------------

/// Load a single track and stream decoded PCM into `pcm_tx`.
///
/// Returns the HTTP status that should be sent to the client:
///   - StatusCode::OK (200) on EndOfTrack / Stopped — normal completion
///   - StatusCode::NOT_FOUND (404) on Unavailable — track not in catalog or region-locked
///   - StatusCode::INTERNAL_SERVER_ERROR on unexpected channel close
///
/// Per-request Player instances: a new Player is created for each request.
/// The Session is shared — audio keys cached at session level are reused across
/// Players on the same session, preserving the audio-key caching benefit (Pitfall 2 / D-04).
pub async fn serve_track_request(
    track_id: &str,
    session: Session,
    pcm_tx: mpsc::Sender<Bytes>,
    start_position_ms: u32,
) -> StatusCode {
    // Create a per-request Player.
    // The factory closure captures a clone of pcm_tx for BrowseHttpSink.
    // Player::new() spawns its own std::thread with tokio Runtime for decoding.
    let pcm_tx_clone = pcm_tx.clone();
    let player = Player::new(
        PlayerConfig::default(),
        session,
        Box::new(NoOpVolume),
        move || BrowseHttpSink::open(None, AudioFormat::S16, pcm_tx_clone),
    );

    // Build Spotify URI from validated track ID.
    // track_id is pre-validated as [A-Za-z0-9]+ by handle_request().
    let uri_str = format!("spotify:track:{}", track_id);
    let uri = match SpotifyUri::from_uri(&uri_str) {
        Ok(u) => u,
        Err(e) => {
            log::warn!("[spoton/browse] SpotifyUri::from_uri failed for {}: {}", uri_str, e);
            return StatusCode::BAD_REQUEST;
        }
    };

    // Load and start playback.
    // true = play immediately, start_position_ms = seek offset (0 for normal start).
    player.load(uri, true, start_position_ms);

    // Event loop: wait for Unavailable (404) or EndOfTrack/Stopped (200).
    // Other events (Loading, Playing, VolumeChanged, etc.) are ignored.
    let mut events = player.get_player_event_channel();
    loop {
        match events.recv().await {
            Some(PlayerEvent::Unavailable { track_id: tid, .. }) => {
                log::info!("[spoton/browse] track {} unavailable", tid);
                return StatusCode::NOT_FOUND;
            }
            Some(PlayerEvent::EndOfTrack { .. }) => {
                log::debug!("[spoton/browse] track {} EndOfTrack", track_id);
                // pcm_tx is dropped here (out of scope), which closes the channel and
                // signals EOF to the ReceiverStream → StreamBody → LMS HTTP client.
                return StatusCode::OK;
            }
            Some(PlayerEvent::Stopped { .. }) => {
                log::debug!("[spoton/browse] track {} Stopped", track_id);
                return StatusCode::OK;
            }
            Some(_) => {
                // Ignore other events (Loading, Playing, TrackChanged, etc.).
                continue;
            }
            None => {
                // Player event channel closed unexpectedly (Player dropped or panicked).
                log::warn!("[spoton/browse] player event channel closed for track {}", track_id);
                return StatusCode::INTERNAL_SERVER_ERROR;
            }
        }
    }
}

// SpotOn librespot integration binary for Lyrion Music Server
//
// Phase 4.1 implementation: --single-track subcommand for LMS transcoding pipeline
// Phase 04.2 implementation: --token-login subcommand for credential provisioning
// Phase 04.3 implementation: --discover-once subcommand for ZeroConf credential acquisition
// Phase 05.1 implementation: --connect mode (Spirc + HTTP streaming + LMS event dispatch)
// Phase 29.1 implementation: --unified mode (Browse + Connect in one process)
//
// Modes:
//   --check          : Print capability manifest (Phase 1 contract, unchanged)
//   --authenticate   : Acquire credentials via username/password, write credentials.json
//   --get-token      : Read cached credentials, return Web API token JSON to stdout
//   --single-track   : Decode one Spotify track to stdout (pipe backend) and exit
//   --token-login    : Acquire reusable credentials from OAuth access token, write credentials.json
//   --discover-once  : ZeroConf mDNS announcement, wait for Spotify App connection, write credentials.json
//   --connect        : Spotify Connect receiver (Spirc + HTTP streaming + LMS JSON-RPC)
//   --unified        : Combined Browse+Connect daemon (one process, one port, optional Spirc)
//
// --check output format:
//   Line 1: "ok spoton v{VERSION}"
//   Line 2: JSON capability manifest
//
// --authenticate contract (for Settings.pm):
//   Command: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>
//   stdout: "authorized" on success
//   exit 0 on success, non-zero on failure
//
// --get-token contract (for TokenManager.pm):
//   Command: spoton -n 'SpotOn' --cache <dir> --get-token [--scope <scopes>]
//   stdout: {"accessToken":"<token>","expiresIn":<seconds>}
//   exit 0 on success, non-zero on failure
//
// --token-login contract (for TokenManager.pm):
//   Command: spoton -n 'SpotOn' --token-login --token <access_token> --cache <dir>
//   stdout: "credentials_saved" on success
//   exit 0 on success, non-zero on failure
//
// --discover-once contract (for Settings.pm / TokenManager.pm):
//   Command: spoton -n 'LMS-Server-Name' --cache <dir> --discover-once
//   stdout line 1: "credentials_saved"
//   stdout line 2: spotify_username
//   exit 0 on success, exit 1 on failure (including 15-min timeout)
//
// --single-track contract (for custom-convert.conf):
//   Command: spoton -n 'SpotOn' -c <dir> --single-track <spotify:track:ID>
//            --bitrate 320 [--passthrough] --disable-discovery --disable-audio-cache
//            [--start-position <secs>]
//   stdout: raw PCM (S16LE) or raw OGG Vorbis (when --passthrough)
//   exit 0 on success (EndOfTrack or Stopped)
//   exit 1 on failure: unavailable track (region-locked, removed, CDN error),
//                      playback timeout (5s safety net), or session/auth error
//   stderr: descriptive error message on exit 1 (track ID, reason)

mod connect;
mod browse;   // Phase 28: persistent Browse daemon (GET /track/{id} HTTP server)
mod unified;  // Phase 29: unified Browse+Connect daemon (one process, one port)

use std::env;
use std::process;

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::{Session, SpotifyUri};

// Phase 04.3: ZeroConf Discovery imports
use librespot_discovery::{DeviceType, Discovery};
use futures_util::StreamExt;
use tokio::time::{timeout, Duration};

use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player, PlayerEvent};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, PartialEq)]
enum Mode {
    Check,
    Authenticate,
    GetToken,
    Connect,
    SingleTrack,
    TokenLogin,    // Phase 04.2: credential provisioning from OAuth access token
    DiscoverOnce,  // Phase 04.3: ZeroConf mDNS credential acquisition
    Browse,        // Phase 28: persistent Browse daemon (GET /track/{id} HTTP server)
    Unified,       // Phase 29: combined Browse+Connect daemon (one process, one port)
}

#[tokio::main]
async fn main() {
    env_logger::init();
    let args: Vec<String> = env::args().collect();

    let mut mode = Mode::Check;
    let mut _name_provided = false;
    let mut device_name = String::new();
    let mut username = String::new();
    let mut password = String::new();
    let mut token_str = String::new();
    let mut cache_dir = String::new();
    let mut scope = String::new();
    let mut client_id = String::new();

    // Single-track mode variables
    let mut track_uri = String::new();
    let mut bitrate_str = String::new();
    let mut passthrough = false;
    let mut start_position_str = String::new();
    let mut disable_audio_cache = false;
    let mut normalisation = false;

    // Connect mode variables
    let mut player_mac = String::new();
    let mut lms_host = String::new();
    let mut lms_auth = String::new();
    let mut disable_discovery = false;
    let mut buffer_latency_ms: u64 = 2000;
    let mut autoplay: Option<bool> = None;
    let mut initial_volume_lms: Option<u8> = None;
    let mut volume_ctrl_str = String::from("log");

    // Phase 29: unified mode variable
    let mut enable_connect = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--check" => {
                mode = Mode::Check;
            }
            "--authenticate" => {
                mode = Mode::Authenticate;
            }
            "--get-token" => {
                mode = Mode::GetToken;
            }
            "--connect" => {
                mode = Mode::Connect;
            }
            "--single-track" => {
                mode = Mode::SingleTrack;
                if i + 1 < args.len() && !args[i + 1].starts_with("--") {
                    track_uri = args[i + 1].clone();
                    i += 1;
                }
            }
            "--token-login" => {
                mode = Mode::TokenLogin;
            }
            "--discover-once" => {
                mode = Mode::DiscoverOnce;
            }
            "--browse" => {
                mode = Mode::Browse;
            }
            "--unified" => {
                mode = Mode::Unified;
            }
            "--enable-connect" => {
                enable_connect = true;
            }
            "--token" => {
                if i + 1 < args.len() {
                    token_str = args[i + 1].clone();
                    i += 1;
                }
            }
            "--bitrate" | "-b" => {
                if i + 1 < args.len() {
                    bitrate_str = args[i + 1].clone();
                    i += 1;
                }
            }
            "--passthrough" => {
                passthrough = true;
            }
            "--start-position" => {
                if i + 1 < args.len() {
                    start_position_str = args[i + 1].clone();
                    i += 1;
                }
            }
            "--disable-discovery" => {
                disable_discovery = true;
            }
            "--player-mac" => {
                if i + 1 < args.len() {
                    player_mac = args[i + 1].clone();
                    i += 1;
                }
            }
            "--lms" => {
                if i + 1 < args.len() {
                    lms_host = args[i + 1].clone();
                    i += 1;
                }
            }
            "--lms-auth" => {
                if i + 1 < args.len() {
                    lms_auth = args[i + 1].clone();
                    i += 1;
                }
            }
            "--buffer-latency-ms" => {
                if i + 1 < args.len() {
                    buffer_latency_ms = args[i + 1].parse().unwrap_or(2000);
                    i += 1;
                }
            }
            "--autoplay" => {
                if i + 1 < args.len() {
                    autoplay = match args[i + 1].as_str() {
                        "on"  => Some(true),
                        "off" => Some(false),
                        _     => None,
                    };
                    i += 1;
                }
            }
            "--initial-volume" => {
                if i + 1 < args.len() {
                    initial_volume_lms = args[i + 1].parse::<u8>().ok().map(|v| v.min(100));
                    i += 1;
                }
            }
            "--volume-ctrl" => {
                if i + 1 < args.len() {
                    volume_ctrl_str = args[i + 1].clone();
                    i += 1;
                }
            }
            "--disable-audio-cache" => {
                disable_audio_cache = true;
            }
            "--enable-volume-normalisation" => {
                normalisation = true;
            }
            "-n" | "--name" => {
                if i + 1 < args.len() {
                    _name_provided = true;
                    device_name = args[i + 1].clone();
                    i += 1;
                }
            }
            "--username" | "-u" => {
                if i + 1 < args.len() {
                    username = args[i + 1].clone();
                    i += 1;
                }
            }
            "--password" | "-p" => {
                if i + 1 < args.len() {
                    password = args[i + 1].clone();
                    i += 1;
                }
            }
            "--cache" | "-c" => {
                if i + 1 < args.len() {
                    cache_dir = args[i + 1].clone();
                    i += 1;
                }
            }
            "--scope" => {
                if i + 1 < args.len() {
                    scope = args[i + 1].clone();
                    i += 1;
                }
            }
            "--client-id" => {
                if i + 1 < args.len() {
                    client_id = args[i + 1].clone();
                    i += 1;
                }
            }
            _ => {
                // Ignore unknown flags for forward compatibility
            }
        }
        i += 1;
    }

    // Convert LMS volume scale (0-100) to librespot u16 scale (0-65535)
    let initial_volume_u16: Option<u16> = initial_volume_lms.map(|v| (v as u32 * 65535 / 100) as u16);

    match mode {
        Mode::Check => {
            // Phase 1 --check contract — Regex in Helper.pm: /^ok spoton v([\d\.]+)/i
            println!("ok spoton v{}", VERSION);
            // Report passthrough capability based on compiled features
            let has_passthrough = cfg!(feature = "passthrough-decoder");
            let json = serde_json::json!({
                "version": VERSION,
                "autoplay": true,
                "browse": true,           // Phase 28: persistent Browse daemon capability
                "discover-once": true,
                "lms-auth": false,
                "ogg-direct": has_passthrough,
                "passthrough": has_passthrough,
                "token-login": true,
                "unified": true,          // Phase 29: unified Browse+Connect daemon capability
            });
            println!("{}", json);
            process::exit(0);
        }

        Mode::Authenticate => {
            if username.is_empty() {
                eprintln!("Error: --username is required for --authenticate");
                eprintln!("Usage: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>");
                process::exit(1);
            }
            if password.is_empty() {
                eprintln!("Error: --password is required for --authenticate");
                eprintln!("Usage: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>");
                process::exit(1);
            }
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --authenticate");
                eprintln!("Usage: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>");
                process::exit(1);
            }

            match run_authenticate(&username, &password, &cache_dir).await {
                Ok(_) => {
                    println!("authorized");
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Authentication failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::GetToken => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --get-token");
                eprintln!("Usage: spoton -n 'SpotOn' --cache <dir> --get-token [--scope <scopes>]");
                process::exit(1);
            }

            match run_get_token(&cache_dir, &scope, &client_id).await {
                Ok(_) => {
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Token retrieval failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::Connect => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --connect");
                eprintln!("Usage: spoton -n 'DeviceName' -c <dir> --connect --player-mac <mac> --lms <host:port>");
                process::exit(1);
            }

            match connect::run_connect(
                &cache_dir,
                &device_name,
                if player_mac.is_empty() { None } else { Some(&player_mac) },
                if lms_host.is_empty() { None } else { Some(&lms_host) },
                if lms_auth.is_empty() { None } else { Some(&lms_auth) },
                disable_discovery,
                buffer_latency_ms,
                autoplay,
                initial_volume_u16,
                &volume_ctrl_str,
            )
            .await
            {
                Ok(_) => process::exit(0),
                Err(e) => {
                    eprintln!("Connect mode error: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::TokenLogin => {
            if token_str.is_empty() {
                eprintln!("Error: --token is required for --token-login");
                eprintln!("Usage: spoton -n 'SpotOn' --token-login --token <access_token> --cache <dir>");
                process::exit(1);
            }
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --token-login");
                eprintln!("Usage: spoton -n 'SpotOn' --token-login --token <access_token> --cache <dir>");
                process::exit(1);
            }

            match run_token_login(&token_str, &cache_dir).await {
                Ok(_) => {
                    println!("credentials_saved");
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Token login failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::DiscoverOnce => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --discover-once");
                eprintln!("Usage: spoton -n 'LMS-Server' --cache <dir> --discover-once");
                process::exit(1);
            }

            match run_discover_once(&device_name, &cache_dir).await {
                Ok(username) => {
                    println!("credentials_saved");
                    println!("{}", username);
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Discovery failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::SingleTrack => {
            if track_uri.is_empty() {
                eprintln!("Error: track URI is required for --single-track");
                eprintln!("Usage: spoton -n 'SpotOn' -c <dir> --single-track <spotify:track:ID> --bitrate 320");
                process::exit(1);
            }
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --single-track");
                eprintln!("Usage: spoton -n 'SpotOn' -c <dir> --single-track <spotify:track:ID> --bitrate 320");
                process::exit(1);
            }

            let bitrate: u32 = bitrate_str.parse().unwrap_or(320);
            let start_position: f64 = start_position_str.parse().unwrap_or(0.0);

            match run_single_track(
                &cache_dir,
                &track_uri,
                bitrate,
                passthrough,
                start_position,
                disable_audio_cache,
                normalisation,
            )
            .await
            {
                Ok(_) => process::exit(0),
                Err(e) => {
                    eprintln!("Single-track playback failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::Browse => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --browse");
                eprintln!("Usage: spoton -n 'DeviceName' -c <dir> --browse --player-mac <mac>");
                process::exit(1);
            }

            match browse::run_browse(
                &cache_dir,
                if player_mac.is_empty() { None } else { Some(&player_mac) },
            )
            .await
            {
                Ok(_) => process::exit(0),
                Err(e) => {
                    eprintln!("Browse mode error: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::Unified => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --unified");
                eprintln!("Usage: spoton -c <dir> --unified --player-mac <mac>");
                eprintln!("       spoton -n 'DeviceName' -c <dir> --unified --player-mac <mac> --enable-connect --lms <host:port>");
                process::exit(1);
            }

            match unified::run_unified(
                &cache_dir,
                &device_name,
                if player_mac.is_empty() { None } else { Some(&player_mac) },
                if lms_host.is_empty() { None } else { Some(&lms_host) },
                if lms_auth.is_empty() { None } else { Some(&lms_auth) },
                enable_connect,
                disable_discovery,
                buffer_latency_ms,
                autoplay,
                initial_volume_u16,
                &volume_ctrl_str,
            )
            .await
            {
                Ok(_) => process::exit(0),
                Err(e) => {
                    eprintln!("Unified mode error: {}", e);
                    process::exit(1);
                }
            }
        }
    }
}

/// Authenticate with Spotify via login5 username/password.
/// On success, writes credentials.json to cache_dir and returns Ok(()).
async fn run_authenticate(
    username: &str,
    password: &str,
    cache_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let credentials = Credentials::with_password(username, password);

    // Cache object: credentials_path = cache_dir, no volume/audio paths
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));

    // connect() with store_credentials=true saves credentials.json to cache_dir
    session.connect(credentials, true).await?;

    Ok(())
}

/// Acquire reusable credentials from a Spotify OAuth access token.
///
/// Calls Credentials::with_access_token() (auth_type = AUTHENTICATION_SPOTIFY_TOKEN,
/// verified in librespot-core-0.8.0/src/authentication.rs:61-67), then connects with
/// store_credentials=true. librespot-core performs the token->reusable_credentials
/// exchange internally (session.rs:184-201, session.rs:249-258) and writes
/// credentials.json to cache_dir.
///
/// No manual reconnect needed — librespot handles the double-connect internally
/// (RESEARCH.md Pitfall 1).
async fn run_token_login(
    access_token: &str,
    cache_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Credentials::with_access_token() sets auth_type = AUTHENTICATION_SPOTIFY_TOKEN
    let credentials = Credentials::with_access_token(access_token);

    // Cache object: credentials_path = cache_dir, no volume/audio paths
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));

    // store_credentials=true: librespot-core connects, receives reusable_auth_credentials
    // from Spotify AP, and writes credentials.json to cache_dir automatically
    session.connect(credentials, true).await?;

    Ok(())
}

/// Read cached credentials from cache_dir, connect to Spotify, and
/// retrieve a Web API access token. Prints JSON to stdout:
///   {"accessToken":"<token>","expiresIn":<seconds>}
async fn run_get_token(
    cache_dir: &str,
    scope: &str,
    client_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Load cached credentials from credentials.json in cache_dir
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;

    let credentials = match cache.credentials() {
        Some(c) => c,
        None => {
            return Err(format!(
                "No cached credentials found in '{}'. Run --authenticate first.",
                cache_dir
            )
            .into());
        }
    };

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, None);

    // Connect using cached credentials (store_credentials=false — already stored)
    session.connect(credentials, false).await?;

    // Determine scopes to request
    let scopes_str = if scope.is_empty() {
        // Default scopes required by SpotOn plugin
        "user-read-private,user-read-email,user-library-read,user-library-modify,\
         user-read-playback-state,user-modify-playback-state,user-read-currently-playing,\
         user-read-recently-played,user-top-read,user-read-playback-position,\
         playlist-read-private,playlist-read-collaborative,\
         playlist-modify-public,playlist-modify-private,\
         user-follow-read,user-follow-modify"
            .to_string()
    } else {
        scope.to_string()
    };

    // Get token via Keymaster/Mercury protocol
    let token = if client_id.is_empty() {
        session.token_provider().get_token(&scopes_str).await?
    } else {
        session.token_provider().get_token_with_client_id(&scopes_str, client_id).await?
    };

    // expires_in is a Duration — convert to whole seconds for the JSON contract
    let expires_in_secs = token.expires_in.as_secs();

    // Print JSON to stdout as required by TokenManager.pm
    // Contract: {"accessToken":"<token>","expiresIn":<seconds>}
    let json = serde_json::json!({
        "accessToken": token.access_token,
        "expiresIn": expires_in_secs,
    });
    println!("{}", json);

    Ok(())
}

/// ZeroConf Discovery: announce via mDNS, wait for first Spotify App connection,
/// write credentials.json, return spotify_username.
///
/// Contract for Perl layer (stdout):
///   Line 1: "credentials_saved"
///   Line 2: spotify_username
///   exit 0 on success, exit 1 on failure (including 15-min timeout)
///
/// Timeout: 15 minutes (900 seconds), matching Spotty pattern.
async fn run_discover_once(
    device_name: &str,
    cache_dir: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    // Stable device_id from cache_dir via FNV-1a (not DefaultHasher which
    // is version-specific and would cause duplicate Spotify devices on rebuild).
    let device_id = {
        let mut h: u64 = 14695981039346656037;
        for b in cache_dir.as_bytes() { h ^= *b as u64; h = h.wrapping_mul(1099511628211); }
        format!("{:016x}", h)
    };

    // KEYMASTER_CLIENT_ID — standard librespot client ID
    // Source: librespot-core-0.8.0/src/config.rs line 6
    const KEYMASTER_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";

    // Build Discovery: starts mDNS announcement and HTTP server for Spotify Connect
    // builder() requires T: Into<String> + 'static; use owned Strings
    let device_name_owned = device_name.to_string();
    let mut discovery = Discovery::builder(device_id, KEYMASTER_CLIENT_ID.to_string())
        .name(device_name_owned)
        .device_type(DeviceType::Speaker)
        .launch()?;

    // Wait for first connection with 15-minute timeout (RESEARCH.md Pitfall 7)
    let credentials = timeout(
        Duration::from_secs(900),
        discovery.next(),
    )
    .await
    .map_err(|_| "Discovery timeout after 15 minutes — no Spotify App connected")?
    .ok_or("Discovery stream ended without credentials")?;

    // Write credentials.json via session.connect(creds, store_credentials=true)
    // Source: run_authenticate() pattern
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;
    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));
    session.connect(credentials, true).await?;

    // Read username from credentials.json (safer than session.username() — RESEARCH Open Q1)
    // credentials.json format: {"username":"...","auth_type":1,"auth_data":"..."}
    let creds_path = std::path::Path::new(cache_dir).join("credentials.json");
    let creds_json = std::fs::read_to_string(&creds_path)?;
    let creds_data: serde_json::Value = serde_json::from_str(&creds_json)?;
    let username = creds_data["username"]
        .as_str()
        .ok_or("username field missing in credentials.json")?
        .to_string();

    Ok(username)
}

/// Decode a single Spotify track to stdout via the pipe audio backend.
///
/// This is the core of the LMS transcoding pipeline integration:
///   custom-convert.conf invokes: spoton ... --single-track <URI> --bitrate 320
///   Output: raw S16LE PCM at 44100 Hz stereo (default) OR
///           raw OGG Vorbis container when --passthrough is set
///
/// The LMS transcoding pipeline (FLAC encoder) consumes stdout.
/// OGG-direct mode (--passthrough) bypasses decoding for CPU-constrained devices.
async fn run_single_track(
    cache_dir: &str,
    track_uri: &str,
    bitrate: u32,
    passthrough: bool,
    start_position_secs: f64,
    disable_audio_cache: bool,
    normalisation: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    // Set up cache — audio cache path only if not disabled
    let audio_cache_path: Option<&str> = if disable_audio_cache {
        None
    } else {
        Some(cache_dir)
    };
    let cache = Cache::new(Some(cache_dir), None::<&str>, audio_cache_path, None)?;

    let credentials = match cache.credentials() {
        Some(c) => c,
        None => {
            return Err(format!(
                "No cached credentials found in '{}'. Run --authenticate first.",
                cache_dir
            )
            .into());
        }
    };

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));
    session.connect(credentials, false).await?;

    // Configure player
    let player_config = PlayerConfig {
        bitrate: match bitrate {
            96 => Bitrate::Bitrate96,
            160 => Bitrate::Bitrate160,
            _ => Bitrate::Bitrate320,
        },
        passthrough,
        normalisation,
        ..PlayerConfig::default()
    };

    // Use pipe backend (stdout) — always available, not feature-gated.
    // SinkBuilder = fn(Option<String>, AudioFormat) -> Box<dyn Sink>
    let backend: audio_backend::SinkBuilder = audio_backend::find(Some("pipe".to_string()))
        .expect("Pipe audio backend not found — this is a build error");

    let audio_format = AudioFormat::default();

    // Player::new returns Arc<Player>; VolumeGetter = NoOpVolume (full volume, no attenuation)
    let player = Player::new(
        player_config,
        session,
        Box::new(NoOpVolume),
        move || backend(None, audio_format),
    );

    // Normalize URI: LMS passes spoton://track:ID, librespot needs spotify:track:ID
    let normalized_uri = track_uri.replace("spoton://", "spotify:");

    // SpotifyUri::from_uri validates the URI format; malformed URIs return Err (T-04.1-05)
    let track_id = SpotifyUri::from_uri(&normalized_uri)?;

    // Start playback; position in milliseconds (clamped to valid u32 range)
    let start_position_ms = if start_position_secs < 0.0 {
        0u32
    } else {
        (start_position_secs * 1000.0).min(u32::MAX as f64) as u32
    };
    player.load(track_id, true, start_position_ms);

    // Listen for player events to detect unavailable tracks and normal completion.
    //
    // We use get_player_event_channel() instead of await_end_of_track() because
    // await_end_of_track() only returns on EndOfTrack/Stopped — it never returns on
    // Unavailable, causing the process to hang forever when a track is region-locked,
    // removed from catalog, or has no audio file for the current CDN region.
    //
    // A 5-second timeout wraps the entire loop as a safety net against any other
    // hang scenario (T-26-01: Denial of Service via indefinite hang).
    let mut event_channel = player.get_player_event_channel();

    let result = timeout(Duration::from_secs(5), async {
        loop {
            match event_channel.recv().await {
                Some(PlayerEvent::EndOfTrack { .. }) => {
                    // Normal completion — track played to the end
                    break Ok(());
                }
                Some(PlayerEvent::Stopped { .. }) => {
                    // Player stopped (e.g., by external signal) — treat as success
                    break Ok(());
                }
                Some(PlayerEvent::Unavailable { track_id, .. }) => {
                    // Track unavailable: region-locked, removed from catalog, or CDN error.
                    // librespot has already printed the reason to stderr.
                    // Returning Err causes main() to eprintln + exit(1), closing the pipe
                    // so LMS advances to the next track automatically.
                    eprintln!("Track unavailable: {}", track_id);
                    break Err(format!("Track unavailable: {}", track_id));
                }
                Some(_) => {
                    // Ignore other events (Loading, Playing, VolumeChanged, etc.)
                    continue;
                }
                None => {
                    // Channel closed unexpectedly (player dropped)
                    break Err("Player event channel closed unexpectedly".to_string());
                }
            }
        }
    })
    .await;

    match result {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.into()),
        Err(_elapsed) => Err("Single-track playback timed out after 5s".into()),
    }
}

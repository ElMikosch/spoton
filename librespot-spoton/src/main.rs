// SpotOn librespot integration binary for Lyrion Music Server
//
// Phase 4.1 implementation: --single-track subcommand for LMS transcoding pipeline
//
// Modes:
//   --check          : Print capability manifest (Phase 1 contract, unchanged)
//   --authenticate   : Acquire credentials via username/password, write credentials.json
//   --get-token      : Read cached credentials, return Web API token JSON to stdout
//   --single-track   : Decode one Spotify track to stdout (pipe backend) and exit
//   --connect        : Not yet implemented (Phase 5)
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
// --single-track contract (for custom-convert.conf):
//   Command: spoton -n 'SpotOn' -c <dir> --single-track <spotify:track:ID>
//            --bitrate 320 [--passthrough] --disable-discovery --disable-audio-cache
//            [--start-position <secs>]
//   stdout: raw PCM (S16LE) or raw OGG Vorbis (when --passthrough)
//   exit 0 on success, non-zero on failure

use std::env;
use std::process;

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::{Session, SpotifyUri};

use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::Player;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, PartialEq)]
enum Mode {
    Check,
    Authenticate,
    GetToken,
    Connect,
    SingleTrack,
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = env::args().collect();

    let mut mode = Mode::Check;
    let mut _name_provided = false;
    let mut username = String::new();
    let mut password = String::new();
    let mut cache_dir = String::new();
    let mut scope = String::new();
    // --client-id accepted for forward compatibility but not used in librespot-core flow
    let mut _client_id = String::new();

    // Single-track mode variables
    let mut track_uri = String::new();
    let mut bitrate_str = String::new();
    let mut passthrough = false;
    let mut start_position_str = String::new();
    let mut disable_audio_cache = false;
    let mut normalisation = false;

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
                // Accepted and ignored — not relevant for single-track mode
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
                    _client_id = args[i + 1].clone();
                    i += 1;
                }
            }
            _ => {
                // Ignore unknown flags for forward compatibility
            }
        }
        i += 1;
    }

    match mode {
        Mode::Check => {
            // Phase 1 --check contract — Regex in Helper.pm: /^ok spoton v([\d\.]+)/i
            println!("ok spoton v{}", VERSION);
            // Report passthrough capability based on compiled features
            let has_passthrough = cfg!(feature = "passthrough-decoder");
            let json = serde_json::json!({
                "version": VERSION,
                "lms-auth": false,
                "ogg-direct": has_passthrough,
                "passthrough": has_passthrough,
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

            match run_get_token(&cache_dir, &scope).await {
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
            eprintln!("Connect mode not yet implemented (Phase 5)");
            eprintln!("Use --check, --authenticate, --get-token, or --single-track");
            process::exit(1);
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

/// Read cached credentials from cache_dir, connect to Spotify, and
/// retrieve a Web API access token. Prints JSON to stdout:
///   {"accessToken":"<token>","expiresIn":<seconds>}
async fn run_get_token(
    cache_dir: &str,
    scope: &str,
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
         user-read-recently-played,user-top-read,\
         playlist-read-private,playlist-read-collaborative,\
         playlist-modify-public,playlist-modify-private,\
         user-follow-read,user-follow-modify"
            .to_string()
    } else {
        scope.to_string()
    };

    // Get token via Keymaster/Mercury protocol
    let token = session
        .token_provider()
        .get_token(&scopes_str)
        .await?;

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

    // Normalize URI: LMS passes spotify://track:ID, librespot needs spotify:track:ID
    let normalized_uri = track_uri.replace("spotify://", "spotify:");

    // SpotifyUri::from_uri validates the URI format; malformed URIs return Err (T-04.1-05)
    let track_id = SpotifyUri::from_uri(&normalized_uri)?;

    // Start playback; position in milliseconds
    let start_position_ms = (start_position_secs * 1000.0) as u32;
    player.load(track_id, true, start_position_ms);

    // Wait for EndOfTrack or Stopped; await_end_of_track handles event loop internally
    player.await_end_of_track().await;

    Ok(())
}

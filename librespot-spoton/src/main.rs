// SpotOn librespot integration binary for Lyrion Music Server
//
// Phase 2 implementation: --authenticate and --get-token subcommands
// backed by librespot-core for Spotify auth via login5 protocol.
//
// Modes:
//   --check        : Print capability manifest (Phase 1 contract, unchanged)
//   --authenticate : Acquire credentials via username/password, write credentials.json
//   --get-token    : Read cached credentials, return Web API token JSON to stdout
//   --connect      : Not yet implemented (Phase 5)
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

use std::env;
use std::process;

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::Session;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, PartialEq)]
enum Mode {
    Check,
    Authenticate,
    GetToken,
    Connect,
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = env::args().collect();

    let mut mode = Mode::Check;
    let mut name_provided = false;
    let mut username = String::new();
    let mut password = String::new();
    let mut cache_dir = String::new();
    let mut scope = String::new();
    // --client-id accepted for forward compatibility but not used in librespot-core flow
    let mut _client_id = String::new();

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
            "-n" | "--name" => {
                if i + 1 < args.len() {
                    name_provided = true;
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
            // Phase 1 --check contract — MUST remain unchanged
            // Regex in Helper.pm: /^ok spoton v([\d\.]+)/i
            println!("ok spoton v{}", VERSION);
            let json = format!(
                r#"{{"version":"{}","lms-auth":false,"ogg-direct":false,"passthrough":true}}"#,
                VERSION
            );
            println!("{}", json);
        }

        Mode::Authenticate => {
            // Validate required arguments
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
            // Validate required arguments
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
            eprintln!("Use --check, --authenticate, or --get-token");
            process::exit(1);
        }
    }

    // Suppress unused variable warning for name_provided in non-check modes
    let _ = name_provided;
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

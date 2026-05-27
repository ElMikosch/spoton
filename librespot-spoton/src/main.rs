// SpotOn librespot integration binary for Lyrion Music Server
//
// Phase 1 minimal implementation:
// Implements the --check contract required by Plugins::SpotOn::Helper.pm
//
// --check output format:
//   Line 1: "ok spoton v{VERSION}"
//   Line 2: JSON capability manifest
//
// Future phases will extend this to full librespot integration.

use std::env;
use std::process;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let args: Vec<String> = env::args().collect();

    let mut i = 1;
    let mut check_mode = false;
    let mut name_provided = false;

    while i < args.len() {
        match args[i].as_str() {
            "--check" => {
                check_mode = true;
            }
            "-n" | "--name" => {
                // Accept name parameter — required by LMS Helper.pm helperCheck()
                // spoton -n "SpotOn" --check
                if i + 1 < args.len() {
                    name_provided = true;
                    i += 1; // skip the name argument
                }
            }
            _ => {
                // Ignore unknown flags for forward compatibility
            }
        }
        i += 1;
    }

    if check_mode {
        // Output the --check contract as required by Helper.pm helperCheck()
        // Regex: /^ok spoton v([\d\.]+)/i
        println!("ok spoton v{}", VERSION);

        // JSON capability manifest (second line)
        // Required key: "version"
        // Optional keys: "lms-auth", "ogg-direct"
        let json = format!(
            r#"{{"version":"{}","lms-auth":false,"ogg-direct":false,"passthrough":true}}"#,
            VERSION
        );
        println!("{}", json);
    } else {
        // Usage info for any other invocation
        if !name_provided {
            eprintln!("SpotOn v{} — librespot integration for Lyrion Music Server", VERSION);
            eprintln!();
            eprintln!("Usage:");
            eprintln!("  spoton --check              Print capability manifest and exit");
            eprintln!("  spoton -n <name> --check    Set device name, print manifest and exit");
            eprintln!("  spoton [options]             Start in Connect mode (Phase 2+)");
            eprintln!();
            eprintln!("Phase 1 minimal binary: --check contract only.");
            eprintln!("Full librespot integration will be added in Phase 2+.");
        }
        process::exit(0);
    }
}

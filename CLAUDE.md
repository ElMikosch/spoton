<!-- GSD:project-start source:PROJECT.md -->
## Project

**SpotOn**

A from-scratch Spotify plugin for Lyrion Music Server (LMS), built on lessons learned from the Spotty-NG project. It provides Spotify Browse, Search, Library access and Spotify Connect integration through librespot, with a clean architecture that avoids the historical debt of Herger's Spotty plugin.

**Core Value:** Reliable Spotify playback and Connect integration on LMS — Browse, stream, and control via Spotify app, without 429 bursts, zombie daemons, or audio glitches.

### Constraints

- **Language**: Perl — LMS plugins are Perl modules under `Slim::Plugin::*`
- **Framework**: LMS Plugin API (`OPMLBased`, `SimpleAsyncHTTP`, `Cache`, `Prefs`)
- **Playback engine**: librespot — only open-source Spotify streaming implementation
- **Perl version**: >= 5.10 (LMS floor)
- **No external CPAN deps**: Everything with LMS bundled modules only
- **Spotify Premium**: Required for streaming
- **LMS version**: 8.0+ minimum, full features from 8.5.1
- **UI paradigm**: OPML menu trees — no grid layout, no tabs, no horizontal scrolling
- **Branding**: Pragmatic compliance with Spotify Design Guidelines — correct metadata, attribution where possible, no over-compliance
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Framework
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Perl | >= 5.10 (LMS floor); LMS 9.x ships ~5.38 | Plugin language | LMS plugins are Perl modules under `Slim::Plugin::*`. No alternative. |
| LMS Plugin API | LMS 8.0+ (floor), 8.5.1+ (full), 9.1.1 (latest stable) | Plugin framework | OPMLBased, SimpleAsyncHTTP, Cache, Prefs — this IS the framework. |
| librespot | 0.8.0 (Nov 2024, latest stable) | Spotify streaming + Connect receiver | Only open-source Spotify streaming implementation; Shannon protocol for lossy. |
| Spotify Web API v1 | Current — see endpoint status table below | Browse, Search, Library, Player State | No alternative; OAuth 2.0 required. |
### LMS Plugin API Modules
#### `Slim::Plugin::OPMLBased` — Menu Framework
# Plugin.pm — Registration
# OPML item structure
#### `Slim::Networking::SimpleAsyncHTTP` — Non-Blocking HTTP
# POST with body and headers:
#### `Slim::Networking::SimpleSyncHTTP` — Blocking HTTP (Scanner only)
# ONLY for Importer.pm scanner context:
#### `Slim::Utils::Cache` — Response Caching
# Set with TTL (seconds):
# Get:
# Delete:
- Player/playback state: 0 (never cache, always live)
- Library items (liked songs): 60s
- Artist/album/track metadata: 3600s
- Playlist tracks: 300s (snapshot_id invalidation recommended)
- Browse/category data: 300s
#### `Slim::Utils::Prefs` — Preferences
# Initialize with defaults:
# Global read/write:
# Per-player preferences:
# Validation:
# Change callback:
#### `Slim::Plugin::OnlineLibraryBase` — Library Import
# Required methods:
#### `Slim::Utils::Log` — Structured Logging
# Usage:
#### `Slim::Control::Request` — Event Subscription + Command Dispatch
# Subscribe to player events:
# Unsubscribe:
# Execute a command on a player:
# Register custom CLI command:
### Bundled CPAN Modules Available
| Module | Use Case |
|--------|----------|
| `JSON::XS` | JSON encoding/decoding (fast XS version) |
| `LWP` | HTTP (use SimpleAsyncHTTP instead in plugin context) |
| `URI` | URI construction/parsing |
| `Digest` | MD5 hashing for cache keys |
| `MIME::Base64` | Base64 for OAuth PKCE code_challenge |
| `Crypt::OpenSSL::Random` | Secure random bytes for PKCE code_verifier |
| `HTML::Parser` | HTML parsing if needed for settings |
| `XML::Simple` or `XML::Parser` | XML parsing |
| `DBI` / `DBD::SQLite` | Direct database access (if needed for importer) |
| `Proc::Background` | Background process management (alternative to direct fork) |
| `IO::Socket::SSL` | TLS sockets |
### Protocol Handler Pattern
# In Plugin.pm initPlugin():
# ProtocolHandler.pm — key methods:
### Transcoding (custom-convert.conf)
# SpotOn single-track mode:
# [binary] [flags] | [transcoder]
# Flags: R = remote, T = can seek to time offset, B = bitrate selectable
## librespot
### Build: Audio Backends
| Backend | Feature Flag | Use Case | Default |
|---------|-------------|----------|---------|
| Rodio | `rodio-backend` | Cross-platform, uses ALSA on Linux | Yes |
| ALSA | `alsa-backend` | Linux low-latency | No |
| PulseAudio | `pulseaudio-backend` | Linux PulseAudio | No |
| GStreamer | `gstreamer-backend` | Custom pipelines | No |
| **Pipe** | always included | stdout output for LMS integration | N/A |
| **Subprocess** | always included | spawn child with audio | N/A |
### Discovery Backends (mDNS)
| Backend | Feature Flag | Platform |
|---------|-------------|----------|
| libmdns | `with-libmdns` | All (default, pure Rust) |
| avahi | `with-avahi` | Linux only |
| dns-sd | `with-dns-sd` | macOS/iOS, not Windows |
### TLS Backends
| Backend | Feature Flag | Notes |
|---------|-------------|-------|
| native-tls | `native-tls` | System OpenSSL/SChannel (default) |
| rustls-tls | `rustls-tls` | Pure Rust, no system TLS dependency |
### Key CLI Flags (Runtime)
- `--name <name>` / `-n` — Device name as shown in Spotify app
- `--device-type <type>` — e.g., `speaker`, `avr`, `stb`, `computer`
- `--backend <backend>` — e.g., `pipe`, `alsa`, `pulseaudio`
- `--device <device>` — Audio device to use
- `--format <format>` — `S16`, `S24`, `S24_3`, `S32`, `F32`, `F64`
- `--bitrate <kbps>` / `-b` — `96`, `160`, `320` (Vorbis quality tiers)
- `--passthrough` — Output raw Ogg Vorbis (requires `passthrough-decoder` feature)
- `--enable-volume-normalisation` — Replay Gain
- `--normalisation-method <method>` — `basic` or `dynamic` (basic = simpler, dynamic = loudness-compensated)
- `--initial-volume <0-100>` — Starting volume
- `--cache <dir>` / `-c` — Directory for credentials and audio cache
- `--cache-size-limit <bytes>` — Limit audio cache size
- `--disable-audio-cache` — Disable audio caching entirely
- `--disable-discovery` — Disable mDNS/ZeroConf announcement (no Connect visibility)
- `--device-id <id>` — Stable device ID (use player MAC address for stability)
- `--single-track <uri>` — Decode one track to stdout and exit (for `custom-convert.conf` use)
- `--start-position <seconds>` — Start from offset (seeking support)
- `--lms <host:port>` — Notify LMS of state changes via JSON-RPC
- `--player-mac <mac>` — Identify which LMS player to notify
- `--get-token` — Retrieve Web API token (for OAuth flow integration)
- `--lms-auth` — Use LMS-provided credentials (Keymaster/login5 integration)
- `--check` — Print JSON capability manifest and exit
### Audio Transport: Pipe Backend
- **Default:** Raw stereo S16LE PCM, 44.1 kHz, 2 channels (standard CD format)
- **With `--passthrough`:** Raw Ogg Vorbis container (skip decoding, save CPU)
- **Bit depth:** Configurable via `--format` (S16 default, S24/S32 available)
### Connect Mode Operation
### Supported Platforms for Binary Distribution
| Platform | Target Triple |
|----------|--------------|
| x86_64 Linux | `x86_64-unknown-linux-musl` (static) |
| i386 Linux | `i686-unknown-linux-musl` |
| aarch64 Linux (Pi 4, etc.) | `aarch64-unknown-linux-musl` |
| armv7 Linux (Pi 2/3 32-bit) | `armv7-unknown-linux-musleabihf` |
| macOS | `x86_64-apple-darwin` / `aarch64-apple-darwin` |
| Windows | `x86_64-pc-windows-msvc` |
## Spotify Web API v1
### Critical 2026 Context: Development Mode Restrictions
| Aspect | Old Behavior | New (Feb 2026) |
|--------|-------------|----------------|
| Max test users | 25 | **5** |
| Premium required for app owner | No | **Yes** |
| Batch endpoints (GET /tracks, /albums, etc.) | Available | **Removed** |
| Browse category endpoints | Available | **Removed** |
| Search limit max | 50 | **10** |
| Search default | 20 | **5** |
| `popularity`, `followers` fields | Available | **Removed** |
| `available_markets` on tracks/albums | Available | **Removed** |
### Endpoint Status Table (May 2026)
#### Working in Development Mode
| Endpoint | Path | Scope Required | Notes |
|----------|------|---------------|-------|
| Search | `GET /search` | none | Max limit=10 per type in dev mode |
| Get Track | `GET /tracks/{id}` | none | Batch `GET /tracks` removed in dev mode |
| Get Album | `GET /albums/{id}` | none | Batch `GET /albums` removed in dev mode |
| Get Artist | `GET /artists/{id}` | none | Batch `GET /artists` removed in dev mode |
| Get Playlist | `GET /playlists/{id}` | `playlist-read-private` | |
| Get Playlist Items | `GET /playlists/{id}/items` | `playlist-read-private` | Renamed from `/tracks` |
| Get User's Playlists | `GET /me/playlists` | `playlist-read-private` | |
| Get Saved Tracks | `GET /me/tracks` | `user-library-read` | Max limit=50, offset pagination |
| Get Saved Albums | `GET /me/albums` | `user-library-read` | |
| Get Top Items | `GET /me/top/{type}` | `user-top-read` | type=tracks or artists, time_range param |
| Get Recently Played | `GET /me/player/recently-played` | `user-read-recently-played` | Cursor-based pagination, max 50 |
| Get Playback State | `GET /me/player` | `user-read-playback-state` | |
| Transfer Playback | `PUT /me/player` | `user-modify-playback-state` | |
| Get Devices | `GET /me/player/devices` | `user-read-playback-state` | |
| Play/Resume | `PUT /me/player/play` | `user-modify-playback-state` | |
| Pause | `PUT /me/player/pause` | `user-modify-playback-state` | |
| Skip Next | `POST /me/player/next` | `user-modify-playback-state` | |
| Skip Previous | `POST /me/player/previous` | `user-modify-playback-state` | |
| Seek | `PUT /me/player/seek` | `user-modify-playback-state` | |
| Set Volume | `PUT /me/player/volume` | `user-modify-playback-state` | |
| Get Queue | `GET /me/player/queue` | `user-read-currently-playing` | |
| Add to Queue | `POST /me/player/queue` | `user-modify-playback-state` | |
| Save to Library | `PUT /me/library` | `user-library-modify` | New unified endpoint (Feb 2026) |
| Remove from Library | `DELETE /me/library` | `user-library-modify` | New unified endpoint |
| Check Library | `GET /me/library/contains` | `user-library-read` | New unified endpoint |
| Follow Artists | `PUT /me/following` | `user-follow-modify` | Via new unified endpoint |
| Create Playlist | `POST /me/playlists` | `playlist-modify-public/private` | |
#### Deprecated (available but marked for removal)
| Endpoint | Path | Status | Notes |
|----------|------|--------|-------|
| Get Featured Playlists | `GET /browse/featured-playlists` | DEPRECATED | Still works but marked deprecated |
| Implicit Grant Auth | Auth flow | DEPRECATED | Use PKCE instead |
| Playlist Items (old) | `GET/POST/PUT/DELETE /playlists/{id}/tracks` | DEPRECATED | Use `/items` path |
#### Removed (Development Mode) — Do Not Use
| Endpoint | Path | Removed Since | Replacement |
|----------|------|--------------|-------------|
| Recommendations | `GET /recommendations` | Nov 27, 2024 | None |
| Audio Features | `GET /audio-features/{id}` | Nov 27, 2024 | None |
| Audio Analysis | `GET /audio-analysis/{id}` | Nov 27, 2024 | None |
| Related Artists | `GET /artists/{id}/related-artists` | Nov 27, 2024 | None |
| Artist Top Tracks | `GET /artists/{id}/top-tracks` | Feb 2026 | None |
| New Releases | `GET /browse/new-releases` | Feb 2026 | None |
| Browse Categories | `GET /browse/categories` | Feb 2026 | None |
| Single Category | `GET /browse/categories/{id}` | Feb 2026 | None |
| Several Tracks | `GET /tracks` | Feb 2026 (dev mode) | `GET /tracks/{id}` individually |
| Several Albums | `GET /albums` | Feb 2026 (dev mode) | `GET /albums/{id}` individually |
| Several Artists | `GET /artists` | Feb 2026 (dev mode) | `GET /artists/{id}` individually |
| Get Users Profile | `GET /users/{id}` | Feb 2026 (dev mode) | N/A |
| Get User's Playlists (other) | `GET /users/{id}/playlists` | Feb 2026 (dev mode) | N/A |
| Available Markets | `GET /markets` | Feb 2026 (dev mode) | N/A |
#### Field Removals (Development Mode)
| Object Type | Removed Fields |
|-------------|---------------|
| Track | `available_markets`, `linked_from`, `popularity` |
| Album | `album_group`, `available_markets`, `label`, `popularity` |
| Artist | `followers`, `popularity` |
| User | `country`, `email`, `explicit_content`, `followers`, `product` |
| Show | `available_markets`, `publisher` |
| Playlist | `tracks` → renamed to `items` with structure changes |
### OAuth Scopes for SpotOn
### Rate Limits
- Rolling 30-second window, app-wide (not per-user or per-endpoint)
- Respond to `429` + `Retry-After` header (value in seconds)
- Central throttle component is mandatory (P-01, NFL-03): one `API/Client.pm` through which ALL requests flow
- Proactive burst prevention is preferred over reactive 429 handling
- Batch APIs (e.g., multiple track IDs per request) were available but are removed in dev mode — fetch individually and throttle accordingly
### Keymaster / login5 Authentication
## Alternatives Considered
| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Async HTTP | SimpleAsyncHTTP | LWP::UserAgent | LWP blocks; LMS is single-threaded |
| Async HTTP | SimpleAsyncHTTP | AnyEvent::HTTP | Available in CPAN bundle but overkill; SimpleAsyncHTTP is the LMS idiom |
| JSON | JSON::XS | Mojo::JSON | Mojo not bundled |
| Spotify transport | librespot | Official Spotify SDK | eSDK requires approved partner, NDA, Certomato certification |
| Spotify transport | librespot | Spotify Web Playback SDK | JavaScript only, browser-based |
| Auth | Keymaster/login5 | PKCE flow | PKCE requires browser redirect + Developer App ID per user |
| Auth | Keymaster/login5 | Client Credentials | No user context, can't access `me/*` endpoints |
| Connect audio | HTTP-streaming | FIFO | FIFO has architectural seek latency (P-19) and white noise (P-20) issues |
| mDNS | libmdns (built-in) | Avahi | Avahi is Linux-only; libmdns is cross-platform pure Rust |
| Cross-compile | cross-rs/cross | Native compile on ARM | Native Pi builds too slow (P-11) |
| Featured Playlists | `me/playlists` filtered | `browse/featured-playlists` | Deprecated; Daily Mixes are user-owned playlists accessible via `me/playlists` |
## LMS Version Targeting
| Version | Status | Notes |
|---------|--------|-------|
| LMS 7.x | Herger supports; SpotOn does not | Too much legacy code to maintain |
| LMS 8.0 | Minimum floor | Significant adoption, OPMLBased stable |
| LMS 8.5.1 | Full features | Recommended for primary development |
| LMS 9.0 (Nov 2024) | Active | First "Lyrion" branded release |
| LMS 9.1.1 (Feb 2026) | Current stable | WebSocket client for plugins, artwork hooks |
| LMS 9.2.0-dev | Development | Not stable |
## Installation Skeleton
# No external dependencies required.
# All modules are bundled with LMS.
# Plugin directory structure:
# install.xml minimum:
## Sources
- LMS Plugin API: https://lyrion.org/reference/music-service-plugin/ (HIGH)
- LMS slimserver source: https://github.com/LMS-Community/slimserver (HIGH)
- SimpleAsyncHTTP: https://github.com/LMS-Community/slimserver/blob/49ad8a29d3fc0cac5792509d1887e0ff8585a81d/Slim/Networking/SimpleAsyncHTTP.pm (HIGH)
- Slim::Utils::Prefs: https://github.com/LMS-Community/slimserver/blob/public/7.9/Slim/Utils/Prefs/Namespace.pm (HIGH)
- librespot releases: https://github.com/librespot-org/librespot/releases (HIGH)
- librespot audio backends: https://github.com/librespot-org/librespot/wiki/Audio-Backends (HIGH)
- librespot CHANGELOG: https://docs.rs/crate/librespot/latest/source/CHANGELOG.md (HIGH)
- Spotify Nov 2024 API changes: https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api (HIGH)
- Spotify Feb 2026 API changelog: https://developer.spotify.com/documentation/web-api/references/changes/february-2026 (HIGH)
- Spotify Feb 2026 migration guide: https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide (HIGH)
- Spotify Mar 2026 changelog: https://developer.spotify.com/documentation/web-api/references/changes/march-2026 (HIGH)
- TechCrunch on Feb 2026 dev mode changes: https://techcrunch.com/2026/02/06/spotify-changes-developer-mode-api-to-require-premium-accounts-limits-test-users/ (MEDIUM)
- Herger's spotty (archived): https://github.com/michaelherger/spotty (MEDIUM — archived 2022)
- Herger's Spotty-Plugin: https://github.com/michaelherger/Spotty-Plugin (HIGH)
- LMS 9 changelog: https://lyrion.org/getting-started/changelog-lms9/ (HIGH)
- Qobuz ProtocolHandler (reference implementation): https://github.com/LMS-Community/plugin-Qobuz/blob/master/ProtocolHandler.pm (HIGH)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->

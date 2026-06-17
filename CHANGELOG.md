# Changelog

All notable changes to SpotOn will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.7.0] - 2026-06-17
### Fixed
- Seek bar showed 0:00 duration — seeking was impossible (duration propagation via `$song->duration()`)
- LMS Favorites unplayable — items used `spotify:` URIs instead of `spoton://` URLs
- Queue showed "Loading..." for all tracks after playing album/playlist from Favorites

### Added
- `explodePlaylist`: resolves album, playlist, and show containers from Favorites into playable tracks
- Metadata pre-caching during container resolution — queue shows titles and artwork immediately
- Episode support in async metadata refetch (`_asyncRefetch`)
- `parseDirectHeaders` for Connect DirectStream duration propagation

## [1.6.3] - 2026-06-16
### Fixed
- Follow/Unfollow button restored in show feed with correct offset correction

## [1.6.2] - 2026-06-16
### Fixed
- Episode click opened wrong item when Follow button was present (index shift)

## [1.6.1] - 2026-06-16
### Fixed
- Search results opened wrong item — Material Skin re-request offset bug
- Show save/remove uses correct `me/shows` endpoints instead of unified `me/library`

## [1.6.0] - 2026-06-15
### Added
- Podcast support: browse saved shows, search podcasts, play episodes
- Show details with episode list, explicit content markers
- Follow/Unfollow shows via library actions
- Episode info view with lazy-load show navigation
- Play/Queue/Favorites buttons on track and episode items (songinfo)
- 27 new i18n string keys across 11 languages for podcast UI
- TROUBLESHOOTING.md and enhanced GitHub issue templates

### Changed
- Date and duration formatting refactored to `cstring()` for full i18n support

## [1.5.1] - 2026-06-15
### Fixed
- Docker: daemon uses actual LMS server address instead of hardcoded `127.0.0.1`
- Docker: mDNS discovery routes through LMS host with loopback fallback guard
- Connect reconnect: reset `current_track` on Stopped event to prevent silent playback
- Player Settings now distinguishable from Server Settings in sidebar

### Added
- Credential pre-check before Connect daemon start (prevents crash-loop)
- Built-in diagnostic system: enable in Settings, download diagnostic bundle
- DIAG logging across all modules (Client, TokenManager, Connect, Daemon, ProtocolHandler)
- Clickable link from Server Settings to active player's SpotOn settings
- Settings split into separate server and player settings classes

## [1.5.0] - 2026-06-14
### Added
- Podcast API foundation: `getShow`, `getShowEpisodes`, `getSavedShows`, `search(type=show,episode)`
- Podcast browse: saved shows list, show detail with episodes, podcast search
- `user-read-playback-position` scope for episode resume points
- Setup guide hint in 11 languages

### Fixed
- Dark theme: replaced hardcoded light-theme colors with `rgba`/opacity
- Publisher display: embedded in show name for Default skin compatibility

## [1.4.3] - 2026-06-13
### Fixed
- Deduplicated discovery UI entries
- String test coverage aligned with actual keys

## [1.4.2] - 2026-06-13
### Fixed
- Account switcher UX with add-account discovery feedback
- CI conditional Rust build (skip rebuild when only Perl changes)

## [1.4.1] - 2026-06-12
### Fixed
- Like/Unlike Material Skin compatibility and state display
- Release binary naming collision (platform suffix added)

### Added
- Auto-build plugin ZIP in CI release job

## [1.4.0] - 2026-06-11
### Added
- macOS Universal Binary (Intel + Apple Silicon) via CI `lipo` + ad-hoc codesign
- `Helper.pm` auto-detects macOS and selects `Bin/darwin/spoton`
- Gatekeeper hint on Settings page for macOS users (11 languages)
- macOS build jobs in CI pipeline

## [1.3.0] - 2026-06-10
### Added
- Like/Unlike button for tracks and albums
- Connect credential isolation (per-player cache directories)
- Connect volume sync between Spotify and LMS

## [1.1.0] - 2026-06-06
### Added
- Multi-arch binary distribution (6 Linux targets + Windows)
- Stream metadata in Songinfo (mode, format, bitrate)
- Connect-DSTM (Don't Stop The Music) with Spirc-native autoplay
- Track history with artwork and async re-fetch
- `spoton://` URI scheme for Spotty coexistence
- 11-language i18n, Setup Guide, Credits
- Production deployment with monitoring

## [1.0.0] - 2026-06-03
### Added
- Initial release: Browse, Search, Library via OPML menus
- Single-track streaming with 5 format modes (Auto/OGG/PCM/FLAC/MP3)
- Spotify Connect with bidirectional controls and sync groups
- ZeroConf + Dual-Token Auth (one-click setup via Spotify app)
- Per-player settings (bitrate, format, Connect toggle, Autoplay toggle)
- mDNS discovery for Spotify Connect visibility

[Unreleased]: https://github.com/stiefenm/spoton/compare/v1.6.3...HEAD
[1.6.3]: https://github.com/stiefenm/spoton/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/stiefenm/spoton/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/stiefenm/spoton/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/stiefenm/spoton/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/stiefenm/spoton/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/stiefenm/spoton/compare/v1.4.3...v1.5.0
[1.4.3]: https://github.com/stiefenm/spoton/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/stiefenm/spoton/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/stiefenm/spoton/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/stiefenm/spoton/compare/v1.3.4...v1.4.0
[1.3.0]: https://github.com/stiefenm/spoton/compare/v1.1...v1.3.0
[1.1.0]: https://github.com/stiefenm/spoton/compare/v1.0.0...v1.1
[1.0.0]: https://github.com/stiefenm/spoton/releases/tag/v1.0.0

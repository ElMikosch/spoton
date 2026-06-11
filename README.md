[![Perl Tests](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml/badge.svg)](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml)

# SpotOn

A Spotify plugin for Lyrion Music Server (LMS).

## Background

SpotOn builds on the foundation that [Michael Herger](https://github.com/michaelherger) laid with his [Spotty plugin](https://github.com/michaelherger/Spotty-Plugin) — the original Spotify integration for LMS that served the community for years. Without Herger's pioneering work on Spotty and the broader LMS plugin ecosystem, SpotOn would not exist. Thank you, Michael.

SpotOn is not a fork or a competitor. It is a from-scratch rewrite designed around the current Spotify Web API (including the [February 2026 changes](https://developer.spotify.com/documentation/web-api/references/changes/february-2026)) and the latest librespot releases. Where Spotty had to work around years of accumulated API changes, SpotOn could start fresh.

| | SpotOn | Spotty |
|--|--------|--------|
| **Like / Unlike** | One-click toggle from any track menu | Not available |
| **Audio formats** | OGG, FLAC, PCM, MP3 — configurable per player | PCM, FLAC, MP3 — global setting |
| **Spotify Connect** | Bidirectional sync (play, pause, seek, volume, skip) | Currently disabled |
| **Made For You** | Daily Mixes, Discover Weekly, Daylist, Release Radar | Either Liked Songs or Made For You content (not both) |

## Features

- **Browse** — Search tracks, albums, artists, and playlists; full artist discography with albums, singles, compilations
- **Library** — Liked Songs, Albums, Artists, Playlists, Recently Played, Top Tracks
- **Like / Unlike** — Save or remove tracks from your Liked Songs directly from browse menus
- **Streaming** — Per-player format selection (OGG passthrough, FLAC, PCM, MP3) with 96/160/320 kbps bitrate and volume normalization
- **Spotify Connect** — Full bidirectional control: appear as a Connect device, control from any Spotify client, state syncs both ways
- **Made For You** — Daily Mixes, Discover Weekly, Daylist, Release Radar with locale-aware sorting
- **Don't Stop The Music** — Automatic queue extension using Spotify recommendations
- **Multi-Account** — Switch between Spotify accounts without re-authentication

## Requirements

- LMS 8.0+ (LMS 9.x recommended)
- Spotify Premium account
- Spotify Developer App (recommended) — [create one here](https://developer.spotify.com/dashboard), then enter your Client ID in SpotOn settings. Without your own app, API requests share a default Client ID with stricter rate limits.

## Installation

1. Open **LMS Settings > Plugins > Additional Repositories**
2. Add the repository URL:
   ```
   https://raw.githubusercontent.com/stiefenm/spoton/main/repo.xml
   ```
3. Click **Apply**, then find **SpotOn** in the plugin list and install it
4. Restart LMS when prompted

## License

MIT — see [LICENSE](LICENSE)

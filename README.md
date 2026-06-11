[![Perl Tests](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml/badge.svg)](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml)

# SpotOn

A Spotify plugin for Lyrion Music Server (LMS) — built from scratch for the 2026 Spotify API.

## Why SpotOn?

Herger's Spotty plugin was archived in 2022. Since then, Spotify has removed dozens of API endpoints, tightened developer mode restrictions, and changed authentication flows. SpotOn is a clean-room implementation that works with the current Spotify Web API — no legacy workarounds, no deprecated endpoints.

| | SpotOn | Spotty |
|--|--------|--------|
| **Spotify API** | Current (Feb 2026 unified endpoints) | Archived 2022, uses deprecated endpoints |
| **Like / Unlike** | One-click toggle from any track menu | Not available |
| **Audio formats** | OGG, FLAC, PCM, MP3 — per player | Per player |
| **Spotify Connect** | Bidirectional sync (play, pause, seek, volume, skip) | Disabled / discontinued |
| **Made For You** | Daily Mixes, Discover Weekly, Daylist, Release Radar | Made For You or Liked Songs only |

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

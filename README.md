[![Perl Tests](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml/badge.svg)](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml)

# SpotOn

A Spotify plugin for Lyrion Music Server (LMS).

## Features

- **Browse** — Search tracks, albums, artists, and playlists; browse your library
- **Streaming** — Single-track playback via librespot; OGG passthrough, PCM, FLAC, and MP3 transcoding modes per player
- **Spotify Connect** — Appear as a Connect device in the Spotify app; full playback control from any Spotify client
- **Library** — Liked Songs, Recently Played, Top Tracks

## Requirements

- LMS 8.0+ (LMS 9.x recommended)
- Spotify Premium account

## Installation

1. Open **LMS Settings → Plugins → Additional Repositories**
2. Add the repository URL:
   ```
   https://raw.githubusercontent.com/stiefenm/spoton/main/repo.xml
   ```
3. Click **Apply**, then find **SpotOn** in the plugin list and install it
4. Restart LMS when prompted

## License

MIT — see [LICENSE](LICENSE)

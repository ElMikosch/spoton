package Plugins::SpotOn::API::Client;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Exporter 'import';
our @EXPORT_OK = qw(SPOTON_DEFAULT_CLIENT_ID);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Constants
use constant RATE_LIMIT_DEFAULT_BACKOFF => 5;
use constant MAX_CONCURRENT_REQUESTS    => 3;
use constant API_BASE                   => 'https://api.spotify.com/v1';
use constant REQUEST_TIMEOUT            => 30;
use constant PERSONAL_MIX_CATEGORY      => '0JQ5DAt0tbjZptfcdMSKl3';
# Source: Spotty API.pm:18 (verified: michaelherger/Spotty-Plugin/API.pm)

use constant SPOTON_DEFAULT_CLIENT_ID => 'd420a117a32841c2b3474932e49fb54b';

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# Module-level concurrency counter.
# Must be reset to 0 in Plugin.pm::initPlugin via Client->reset()
# to prevent stale counter after plugin reload (Pitfall 2 from RESEARCH.md).
my $inflightCount = 0;

# API telemetry counters (Phase 32 — Status Page)
my $apiRequestCount = 0;
my $api429Count     = 0;

# ============================================================
# Public class methods
# ============================================================

# reset($class)
# Resets the inflight and telemetry counters. Called by Plugin.pm::initPlugin on startup.
sub reset {
    my ($class) = @_;
    $inflightCount  = 0;
    $apiRequestCount = 0;
    $api429Count     = 0;
    main::INFOLOG && $log->info("Client: inflightCount, apiRequestCount, api429Count reset to 0");
}

# statusSnapshot($class)
# Returns a hashref with current API telemetry for the Status Page.
sub statusSnapshot {
    my $class = shift;
    return {
        inflightCount   => $inflightCount,
        apiRequestCount => $apiRequestCount,
        api429Count     => $api429Count,
        rateLimited     => $cache->get('spoton_rate_limit') ? 1 : 0,
    };
}

# getMe($class, $accountId, $cb)
# Fetches the current user profile (/me).
# $cb->($result) on success; $cb->(undef, $err) on failure.
# Phase 2 implements only this endpoint (D-15). Browse/Search/Library come in Phase 3.
sub getMe {
    my ($class, $accountId, $cb) = @_;
    $class->_request('get', 'me', { _accountId => $accountId, _noCache => 1 }, $cb);
}

# ============================================================
# Browse / Search / Library API methods (Phase 3)
# ============================================================

# search($class, $accountId, $params, $cb)
# Searches Spotify. q is the search query; type defaults to "track,album,artist,playlist";
# limit defaults to 50. Note: Spotify docs claim Dev Mode max is 10, but empirically
# limit=50 works and returns full results. Intentional — do not reduce to 10.
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'search', {
        _accountId => $accountId,
        q          => $params->{q} // '',
        type       => $params->{type}   // 'track,album,artist,playlist',
        limit      => $params->{limit}  // 50,
        offset     => $params->{offset} // 0,
    }, $cb);
}

# recommendations($class, $accountId, $params, $cb)
# Fetches track recommendations from Spotify (/recommendations).
# Parameters: seed_tracks (arrayref), seed_artists (arrayref), seed_genres (arrayref),
#             limit (default 25).
# Requires at least one seed_track or seed_artist to avoid empty result.
# Seed arrayrefs are converted to comma-separated strings for the query.
# _noCache => 1: recommendations should always be fresh (DSTM use case).
# Returns $cb->($result->{tracks}) (arrayref) or $cb->([]) on empty/failure.
sub recommendations {
    my ($class, $accountId, $params, $cb) = @_;

    # Guard: require at least one seed_track or seed_artist (no-op otherwise)
    my @seedTracks  = @{ $params->{seed_tracks}  || [] };
    my @seedArtists = @{ $params->{seed_artists} || [] };
    unless (@seedTracks || @seedArtists) {
        $cb->([]);
        return;
    }

    my %reqParams = (
        _accountId => $accountId,
        _noCache   => 1,
        limit      => $params->{limit} // 25,
    );

    # Convert arrayrefs to comma-separated strings (Spotify API format)
    $reqParams{seed_tracks}  = join(',', @seedTracks)                    if @seedTracks;
    $reqParams{seed_artists} = join(',', @seedArtists)                   if @seedArtists;
    $reqParams{seed_genres}  = join(',', @{ $params->{seed_genres} || [] })
        if $params->{seed_genres} && @{ $params->{seed_genres} };

    $class->_request('get', 'recommendations', \%reqParams, sub {
        my ($result, $err) = @_;
        if (!$result || $err) {
            $cb->([]);
            return;
        }
        $cb->($result->{tracks} || []);
    });
}

# getRecentlyPlayed($class, $accountId, $params, $cb)
# Fetches recently played tracks (/me/player/recently-played).
# Cursor-based — no offset parameter (Pitfall 4).
sub getRecentlyPlayed {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/player/recently-played', {
        _accountId => $accountId,
        _noCache   => 1,
        limit      => $params->{limit} // 50,
    }, $cb);
}

# getTopTracks($class, $accountId, $params, $cb)
# Fetches user's top tracks (/me/top/tracks).
# time_range defaults to "medium_term" (D-05).
sub getTopTracks {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/top/tracks', {
        _accountId => $accountId,
        time_range => $params->{time_range} // 'medium_term',
        limit      => $params->{limit}      // 50,
    }, $cb);
}

# getSavedTracks($class, $accountId, $params, $cb)
# Fetches user's saved (liked) tracks (/me/tracks).
# Offset-paginated; max limit 50.
sub getSavedTracks {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/tracks', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getSavedAlbums($class, $accountId, $params, $cb)
# Fetches user's saved albums (/me/albums).
# Offset-paginated; max limit 50.
sub getSavedAlbums {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/albums', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getFollowedArtists($class, $accountId, $params, $cb)
# Fetches followed artists (/me/following?type=artist).
# Cursor-based (no offset); type=artist is hardcoded (Pitfall 2 — requires user-follow-read scope).
sub getFollowedArtists {
    my ($class, $accountId, $params, $cb) = @_;
    my %reqParams = (
        _accountId => $accountId,
        type       => 'artist',
        limit      => $params->{limit} // 50,
    );
    $reqParams{after} = $params->{after} if defined $params->{after};
    $class->_request('get', 'me/following', \%reqParams, $cb);
}

# getSavedShows($class, $accountId, $params, $cb)
# Fetches user's saved shows (/me/shows). Offset-paginated; max limit 50.
# Scope: user-library-read. Token-routing: me/* hard guard -> own.
sub getSavedShows {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/shows', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
        ($params->{_noCache} ? (_noCache => 1) : ()),
    }, $cb);
}

# saveTracks($class, $accountId, $uris, $cb)
# Saves tracks to the user's library (PUT /me/library?uris=...).
# D-12: Uses unified library endpoint with full Spotify URIs (e.g. spotify:track:ID).
# Response: 200 OK with empty body — handled by empty-body guard in _doFlavouredRequest.
# Scope: user-library-modify
sub saveTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('put', 'me/library', {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

# removeTracks($class, $accountId, $uris, $cb)
# Removes tracks from the user's library (DELETE /me/library?uris=...).
# D-13: Uses unified library endpoint with full Spotify URIs.
# Response: 200 OK with empty body — handled by empty-body guard in _doFlavouredRequest.
# Scope: user-library-modify
sub removeTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('delete', 'me/library', {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

# checkTracks($class, $accountId, $uris, $cb)
# Checks if tracks are saved in the user's library (GET /me/library/contains?uris=...).
# D-14: Response is an array of booleans, e.g. [true] or [false].
# _noCache => 1: caching is managed manually in Plugin.pm with 60s TTL (D-07, Pitfall 2).
# Scope: user-library-read
sub checkTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('get', 'me/library/contains', {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

sub _extractShowIds {
    return join(',', map { /^spotify:show:(.+)$/ ? $1 : $_ } @{$_[0] || []});
}

# saveShows($class, $accountId, $uris, $cb)
# Saves shows to the user's library (PUT /me/shows?ids=...).
# Uses old-style endpoint consistent with GET /me/shows listing.
# The unified PUT /me/library saves to a different store that GET /me/shows does not read.
# Response: 200 OK with empty body — handled by empty-body guard in _doFlavouredRequest.
# Scope: user-library-modify
sub saveShows {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('put', 'me/shows', {
        _accountId => $accountId,
        _noCache   => 1,
        ids        => _extractShowIds($uris),
    }, $cb);
}

# removeShows($class, $accountId, $uris, $cb)
# Removes shows from the user's library (DELETE /me/shows?ids=...).
# Uses old-style endpoint consistent with GET /me/shows listing.
# Response: 200 OK with empty body — handled by empty-body guard in _doFlavouredRequest.
# Scope: user-library-modify
sub removeShows {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('delete', 'me/shows', {
        _accountId => $accountId,
        _noCache   => 1,
        ids        => _extractShowIds($uris),
    }, $cb);
}

# checkShows($class, $accountId, $uris, $cb)
# Checks if shows are saved in the user's library (GET /me/shows/contains?ids=...).
# Uses old-style endpoint consistent with GET /me/shows listing.
# Response is an array of booleans, e.g. [true] or [false].
# _noCache => 1: caching is managed manually in Plugin.pm with 60s TTL (D-07, Pitfall 2).
# Scope: user-library-read
sub checkShows {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('get', 'me/shows/contains', {
        _accountId => $accountId,
        _noCache   => 1,
        ids        => _extractShowIds($uris),
    }, $cb);
}

# getUserPlaylists($class, $accountId, $params, $cb)
# Fetches user's playlists (/me/playlists).
# Offset-paginated; max limit 50.
sub getUserPlaylists {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/playlists', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# addToPlaylist($class, $accountId, $playlistId, $uris, $cb)
# Adds items to a playlist (POST /playlists/{playlistId}/items?uris=...).
# $uris: arrayref of full Spotify URIs (spotify:track:ID or spotify:episode:ID).
# Response: {"snapshot_id": "..."} — parsed normally.
# Scope: playlist-modify-public, playlist-modify-private
sub addToPlaylist {
    my ($class, $accountId, $playlistId, $uris, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $playlistId && $playlistId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('post', "playlists/$playlistId/items", {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

# getPersonalMixes($class, $accountId, $params, $cb)
# Fetches Spotify personal mix playlists via the browse/categories endpoint (D-05).
# Source: Spotty API.pm categoryPlaylists pattern.
# Response structure: {playlists: {items: [...]}} — NOT {items: [...]}.
# Cache TTL: 300s (browse/ path — see _cacheTTL line 396).
sub getPersonalMixes {
    my ($class, $accountId, $params, $cb) = @_;
    my %reqParams = (
        _accountId => $accountId,
        limit      => $params->{limit} // 50,
    );
    $reqParams{offset}  = $params->{offset}  if $params->{offset};
    $reqParams{_locale}  = $params->{_locale}  if $params->{_locale};
    $class->_request('get',
        'browse/categories/' . PERSONAL_MIX_CATEGORY . '/playlists',
        \%reqParams,
        $cb
    );
}

# getArtist($class, $accountId, $artistId, $cb)
# Fetches a single artist by ID (/artists/{artistId}).
sub getArtist {
    my ($class, $accountId, $artistId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $artistId && $artistId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "artists/$artistId", { _accountId => $accountId }, $cb);
}

# getArtistAlbums($class, $accountId, $artistId, $params, $cb)
# Fetches albums for an artist (/artists/{artistId}/albums).
# Per D-09: include_groups takes a SINGLE value per call (album|single|compilation|appears_on).
# Combined values break pagination — callers issue separate requests per type.
sub getArtistAlbums {
    my ($class, $accountId, $artistId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $artistId && $artistId =~ /^[A-Za-z0-9]{1,40}$/;
    my %reqParams = (
        _accountId     => $accountId,
        offset         => $params->{offset} // 0,
        limit          => $params->{limit}  // 50,
    );
    $reqParams{include_groups} = $params->{include_groups}
        if defined $params->{include_groups};
    $class->_request('get', "artists/$artistId/albums", \%reqParams, $cb);
}

# getAlbum($class, $accountId, $albumId, $cb)
# Fetches album metadata including first page of tracks (/albums/{albumId}).
sub getAlbum {
    my ($class, $accountId, $albumId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $albumId && $albumId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "albums/$albumId", { _accountId => $accountId }, $cb);
}

# getAlbumTracks($class, $accountId, $albumId, $params, $cb)
# Fetches paginated track list for an album (/albums/{albumId}/tracks).
# Offset-paginated; max limit 50.
sub getAlbumTracks {
    my ($class, $accountId, $albumId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $albumId && $albumId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "albums/$albumId/tracks", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getShow($class, $accountId, $showId, $cb)
# Fetches show metadata (/shows/{id}). Scope: user-read-playback-position.
sub getShow {
    my ($class, $accountId, $showId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $showId && $showId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "shows/$showId", { _accountId => $accountId }, $cb);
}

# getShowEpisodes($class, $accountId, $showId, $params, $cb)
# Fetches paginated episode list for a show (/shows/{id}/episodes).
# Offset-paginated; max limit 50. Cache TTL: 60s (D-01).
sub getShowEpisodes {
    my ($class, $accountId, $showId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $showId && $showId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "shows/$showId/episodes", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getEpisode($class, $accountId, $episodeId, $cb)
# Fetches a single episode by ID (/episodes/{id}). Scope: user-read-playback-position.
sub getEpisode {
    my ($class, $accountId, $episodeId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $episodeId && $episodeId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "episodes/$episodeId", { _accountId => $accountId }, $cb);
}

# getPlaylistItems($class, $accountId, $playlistId, $params, $cb)
# Fetches paginated items for a playlist (/playlists/{playlistId}/items).
# Uses /items path — NOT /tracks (Pitfall 3: Feb 2026 rename).
# Offset-paginated; max limit 100.
sub getPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $playlistId && $playlistId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "playlists/$playlistId/items", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 100,
    }, $cb);
}

# getTrack($class, $accountId, $trackId, $cb)
# Fetches a single track by ID (/tracks/{trackId}).
# Used by Connect.pm for metadata fetch after start/change events (D-13).
# Track endpoint is available in dev mode (batch GET /tracks removed, but GET /tracks/{id} works).
sub getTrack {
    my ($class, $accountId, $trackId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $trackId && $trackId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "tracks/$trackId", { _accountId => $accountId }, $cb);
}

# ============================================================
# Player Control API methods (D-15 Web API fallback for Connect)
# ============================================================
# These are used as fallback when binary HTTP control endpoints are unreachable.
# Primary control path is POST /control/* on the binary (D-14).

# playerPause($class, $accountId, $cb)
# Pauses playback on the active device (PUT /me/player/pause).
sub playerPause {
    my ($class, $accountId, $cb) = @_;
    $class->_request('put', 'me/player/pause', {
        _accountId => $accountId,
        _noCache   => 1,
    }, $cb);
}

# playerPlay($class, $accountId, $cb)
# Resumes playback on the active device (PUT /me/player/play).
sub playerPlay {
    my ($class, $accountId, $cb) = @_;
    $class->_request('put', 'me/player/play', {
        _accountId => $accountId,
        _noCache   => 1,
    }, $cb);
}

# playerVolume($class, $accountId, $volumePct, $cb)
# Sets volume on the active device (PUT /me/player/volume?volume_percent=N).
sub playerVolume {
    my ($class, $accountId, $volumePct, $cb) = @_;
    $class->_request('put', 'me/player/volume', {
        _accountId      => $accountId,
        _noCache        => 1,
        volume_percent  => int($volumePct),
    }, $cb);
}

# playerSeek($class, $accountId, $positionMs, $cb)
# Seeks to position in current track (PUT /me/player/seek?position_ms=N).
sub playerSeek {
    my ($class, $accountId, $positionMs, $cb) = @_;
    $class->_request('put', 'me/player/seek', {
        _accountId  => $accountId,
        _noCache    => 1,
        position_ms => int($positionMs),
    }, $cb);
}

# ============================================================
# Core request pipeline
# ============================================================

# _request($class, $method, $path, $params, $cb)
# Central HTTP egress point. All Spotify API calls go through here (API-01).
#
# Request pipeline (D-04: single PKCE token per account, no flavor routing):
#   1. Strip leading slash from path
#   2. Rate-limit check (single key, no flavor suffix)
#   3. Response cache check (unless _noCache) (API-03)
#   4. Concurrency cap (API-02) — defer via timer
#   5. Increment inflight counter; wrap $cb in double-callback guard
#   6. Dispatch to _doFlavouredRequest
sub _request {
    my ($class, $method, $path, $params, $cb) = @_;

    # Step 1: Strip leading slash
    my $cleanPath = $path;
    $cleanPath =~ s{^/}{};

    # Step 2: Rate-limit check — single key, no flavor suffix (D-04).
    if ($cache->get('spoton_rate_limit')) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    # Step 3: Concurrency cap (API-02, Pitfall 6).
    if ($inflightCount >= MAX_CONCURRENT_REQUESTS) {
        Slim::Utils::Timers::setTimer(
            undef,
            Time::HiRes::time() + 0.1,
            sub { $class->_request($method, $cleanPath, $params, $cb) }
        );
        return;
    }

    # Step 4: Increment inflight counter and wrap $cb in double-callback guard.
    # $inflightCount is decremented exactly once per request by $userCb.
    $inflightCount++;
    $apiRequestCount++;
    my $userCbCalled = 0;
    my $userCb = sub {
        return if $userCbCalled++;
        $inflightCount--;
        $cb->(@_);
    };

    # Step 5: Dispatch to request handler.
    # H1: eval-guarded — any die after $inflightCount++ must exit through $userCb
    # (the single decrement point with double-call guard), or the counter leaks
    # until MAX_CONCURRENT_REQUESTS is reached and all API traffic deadlocks.
    eval {
        $class->_doFlavouredRequest($method, $cleanPath, $params, $userCb);
        1;
    } or do {
        $log->error("Client: dispatch failed for $cleanPath: $@");
        $userCb->(undef, { error => 'internal_error' });
    };
}

# _doFlavouredRequest($class, $method, $cleanPath, $params, $userCb)
# Executes a single-flavor HTTP request with optional bundled fallback on 403/410/deprecated-404.
# Called from _request(); also called recursively for the bundled retry (isRetry=1).
# Source: Spotty-NG API.pm:1595-1703 adapted
sub _doFlavouredRequest {
    my ($class, $method, $cleanPath, $params, $userCb) = @_;

    my $accountId = $params->{_accountId};

    # M1/H1c: Build URL, query string, and cache key BEFORE any token fetch.
    # A cache hit must never trigger a token fetch.
    # eval-guarded: uri_escape_utf8 or interpolation dies must exit via $userCb.
    # CR-01: Include accountId to prevent multi-account cache contamination.
    my ($url, $queryStr);
    my $built = eval {
        $url = API_BASE . "/$cleanPath";
        my @queryParts;
        for my $key (sort keys %{$params}) {
            next if $key =~ /^_/;
            push @queryParts, "$key=" . uri_escape_utf8($params->{$key});
        }
        $queryStr = join('&', @queryParts);
        if ($queryStr) {
            $url .= '?' . $queryStr;
        }
        1;
    };
    unless ($built) {
        $log->error("Client: request build failed for $cleanPath: $@");
        $userCb->(undef, { error => 'internal_error' });
        return;
    }

    unless ($params->{_noCache}) {
        my $cacheKey = $queryStr
            ? "spoton_resp_${accountId}_${cleanPath}?${queryStr}"
            : "spoton_resp_${accountId}_${cleanPath}";
        $cacheKey .= "_locale=$params->{_locale}" if $params->{_locale};
        $params->{_cacheKey} = $cacheKey;
        if (my $cached = $cache->get($cacheKey)) {
            main::INFOLOG && $log->info("Client: cache hit for $cleanPath (no token fetch needed)");
            $userCb->($cached);
            return;
        }
    }

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->getToken($accountId, sub {
        my $token = shift;

        unless ($token) {
            main::INFOLOG && $log->info("Client: no token available for account $accountId");
            $userCb->(undef, { error => 'no_token' });
            return;
        }

        # T-02-10: Never log Authorization header value — only URL path and method
        main::INFOLOG && $log->info("Client: $method $cleanPath");

        my $reqStartTime = Time::HiRes::time();
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                # Success callback — parse JSON and cache
                my $http = shift;
                my $reqDuration = Time::HiRes::time() - $reqStartTime;
                if ($reqDuration > 2 && $prefs->get('diagnosticMode')) {
                    $log->warn(sprintf("[DIAG] api_slow: endpoint=%s duration=%.1fs", $cleanPath, $reqDuration));
                }
                my $content = $http->content // '';

                # Pitfall 6: PUT/DELETE /me/library returns 200 OK with empty body.
                # from_json('') throws an exception — treat empty/whitespace body as
                # success with undef result (not a parse error). Contract: $err is undef.
                my $result;
                if ($content =~ /\S/) {
                    $result = eval { from_json($content) };
                    if ($@) {
                        $log->error("Client: JSON parse error for $cleanPath: $@");
                        if ($INC{'Plugins/SpotOn/Status.pm'}) {
                            Plugins::SpotOn::Status->recordError('error', 'API', "JSON parse error for $cleanPath");
                        }
                        $userCb->(undef, { error => 'parse_error' });
                        return;
                    }
                }

                # Cache response with domain-specific TTL (API-03).
                unless ($params->{_noCache}) {
                    my $ttl = $class->_cacheTTL($cleanPath);
                    if ($ttl > 0) {
                        my $cacheKey = $params->{_cacheKey} || "spoton_resp_$cleanPath";
                        $cache->set($cacheKey, $result, $ttl);
                        main::INFOLOG && $log->info("Client: cached $cleanPath for ${ttl}s");
                    }
                }

                $userCb->($result);
            },
            sub {
                # Error callback — handle 429, 401, and generic errors
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;
                if (!$code && $error && $error =~ /^(\d{3})\b/) {
                    $code = $1;
                }

                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        # T-02-08: Cap Retry-After at 300s to prevent self-DoS
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 1   if $retryAfter < 1;
                    $retryAfter = 300 if $retryAfter > 300;

                    # Single rate-limit key — no flavor suffix (D-04).
                    $cache->set('spoton_rate_limit', 1, $retryAfter);
                    $api429Count++;
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('warn', 'API', "429 on $cleanPath");
                    }
                    $log->warn("Client: 429 rate limited for ${retryAfter}s on $cleanPath");
                    $log->warn("[DIAG] api_429: endpoint=$cleanPath retry_after=${retryAfter}s") if $prefs->get('diagnosticMode');
                    $userCb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                # 401: Invalidate the account's token cache
                if ($code == 401) {
                    $cache->remove("spoton_token_${accountId}") if $accountId;
                    $log->warn("Client: 401 unauthorized for $cleanPath (token invalidated)");
                    $log->warn("[DIAG] api_401: endpoint=$cleanPath account=" . substr($accountId || '', 0, 4) . "****") if $prefs->get('diagnosticMode');
                    $userCb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                # T-02-10: Log only status code and path, never token value
                $log->error("Client: HTTP $code error for $cleanPath: $error");
                if ($INC{'Plugins/SpotOn/Status.pm'}) {
                    Plugins::SpotOn::Status->recordError('error', 'API', "HTTP $code for $cleanPath");
                }
                $log->warn("[DIAG] api_error: endpoint=$cleanPath code=$code error=$error") if $prefs->get('diagnosticMode');
                $userCb->(undef, { error => $error, code => $code });
            },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        );

        my @headers = (
            'Authorization' => "Bearer $token",
            'Accept'        => 'application/json',
        );
        push @headers, 'Accept-Language' => $params->{_locale} if $params->{_locale};

        # D-04: PUT/POST requests require Content-Length header to avoid 411 Length Required.
        # The Spotify Web API rejects body-less PUT/POST without an explicit Content-Length: 0.
        # Applies to: playerPause, playerPlay, playerVolume, playerSeek Web API fallback calls.
        # Pattern from Spotty-NG API.pm:1907-1909.
        if (uc($method) eq 'PUT' || uc($method) eq 'POST') {
            push @headers, 'Content-Length' => 0;
        }

        # H1c: this closure runs inside the async getToken callback — a die here
        # would escape the eval in _request and leak $inflightCount. Route it
        # through $userCb (double-call guard makes a late duplicate harmless).
        eval {
            $http->$method($url, @headers);
            1;
        } or do {
            $log->error("Client: HTTP dispatch failed for $cleanPath: $@");
            $userCb->(undef, { error => 'internal_error' });
        };
    });
}

# _cacheTTL($path)
# Returns the appropriate cache TTL in seconds for a given API path.
# Based on CLAUDE.md domain-specific cache TTL guidelines.
sub _cacheTTL {
    my ($class, $path) = @_;

    # Playback state: never cache (always live) — also covers me/player/recently-played
    return 0 if $path =~ /^me\/player/;

    # User profile: always fresh
    return 0 if $path eq 'me';

    # Episode lists: 60s (D-01 locked) -- must precede general shows/ rule
    return 60 if $path =~ /^shows\/[^\/]+\/episodes/;

    # Library items: 60 seconds (tracks, albums, top, following, playlists, shows)
    return 60 if $path =~ /^me\/(?:tracks|albums|top|following|playlists|shows)/;

    # Single episode: 300s (on-demand, fresher resume_point)
    return 300 if $path =~ /^episodes\/[^\/]+/;

    # Track/album/artist/show metadata: 3600 seconds (1 hour)
    return 3600 if $path =~ /^(?:tracks|albums|artists|shows)\//;

    # Search results: 300 seconds (5 minutes, same as browse tier)
    return 300 if $path =~ /^search/;

    # Playlists and browse data: 300 seconds (5 minutes)
    return 300 if $path =~ /^(?:playlists|browse)\//;

    # Default: no cache for unknown paths
    return 0;
}

1;

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

# ------------------------------------------------------------
# Web-Player-scoped request constants (Phase 52, D-07)
# ------------------------------------------------------------
# pathfinderHome() and getWebPlayerPlaylistItems() route traffic through the
# Web-Player token (Plugins::SpotOn::API::WebPlayer->getToken), NEVER
# TokenManager->getToken, and isolate their rate-limit state under a
# distinct cache key so a Pathfinder/37i9 429 never sets the Browse
# spoton_rate_limit flag (Pitfall 5, T-52-04).
use constant WP_RATE_LIMIT_KEY     => 'spoton_wp_rate_limit';
use constant WP_GQL_HASH_CACHE_KEY => 'spoton_wp_gql_hash';
use constant PATHFINDER_URL        => 'https://api-partner.spotify.com/pathfinder/v2/query';

# PATHFINDER_HOME_HASH_DEFAULT: persisted-query sha256Hash for the Pathfinder
# "home" GraphQL operation. UNVERIFIED PLACEHOLDER -- RESEARCH Open Question 1 /
# Assumption A4 (LOW confidence): no reliable public feed for this hash was
# found during this phase's research (rotates with every web-player release).
# Must be captured from a live web-player session (DevTools Network tab ->
# pathfinder/v2/query request -> extensions.persistedQuery.sha256Hash) during
# the phase-level manual UAT pass and seeded into the spoton_wp_gql_hash
# cache override (or this constant updated directly). Until replaced, a real
# pathfinderHome() call will most likely receive a PersistedQueryNotFound
# errors[] response and degrade to an empty result -- the designed fail-safe
# (Pitfall 4), not a bug.
use constant PATHFINDER_HOME_HASH_DEFAULT => 'REPLACE_WITH_LIVE_CAPTURED_HOME_PERSISTED_QUERY_HASH';

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

# ============================================================
# Web-Player-scoped methods (Phase 52, D-07) -- Pathfinder discovery +
# 37i9... playlist access. Route through WebPlayer->getToken, NEVER
# TokenManager->getToken, and isolate rate-limit state under
# WP_RATE_LIMIT_KEY (Pitfall 5, T-52-04). Dev-Mode PKCE tokens 404 on ALL
# Spotify-owned (37i9...) playlists regardless of ID validity (Pitfall 3).
# ============================================================

# pathfinderHome($class, $accountId, $params, $cb)
# Discovers algorithmic ("Made for You") playlist IDs -- Daily Mix, Discover
# Weekly, Release Radar, Daylist, genre mixes -- via the Pathfinder "home"
# GraphQL query (POST api-partner.spotify.com/pathfinder/v2/query). Uses
# ONLY the Web-Player token from WebPlayer->getToken (D-07).
# $cb->(\@ids, undef) on success (possibly an empty arrayref).
# $cb->(undef, { error => $reason }) on hard failure: no_spdc / no_secrets /
# expired / mint_failed (propagated from WebPlayer->getToken), or an HTTP/
# rate_limited/parse error from this request itself.
# A PersistedQueryNotFound / top-level errors[] response is NOT a hard
# failure -- it degrades to $cb->([], undef) with a distinct log line
# (Pitfall 4) so Browse is never affected by GraphQL hash rotation.
sub pathfinderHome {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};

    # Isolated Web-Player rate pool (Pitfall 5, T-52-04) -- never the shared
    # 'spoton_rate_limit' key checked by _request().
    if ($cache->get(WP_RATE_LIMIT_KEY)) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    require Plugins::SpotOn::API::WebPlayer;
    Plugins::SpotOn::API::WebPlayer->getToken($accountId, sub {
        my ($tokenHash, $reason) = @_;
        unless ($tokenHash && $tokenHash->{access_token}) {
            main::INFOLOG && $log->info('Client: pathfinderHome no Web-Player token (reason='
                . ($reason || 'unknown') . ')');
            $cb->(undef, { error => $reason || 'no_token' });
            return;
        }

        # GraphQL persisted-query hash is refreshable config (Pitfall 4):
        # prefer a cached override over the shipped placeholder default.
        my $hash = $cache->get(WP_GQL_HASH_CACHE_KEY) || PATHFINDER_HOME_HASH_DEFAULT;

        my $body = eval { to_json({
            operationName => 'home',
            variables     => {
                homeEndUserIntegration => 'INTEGRATION_WEB_PLAYER',
                timeZone               => $params->{timeZone} || 'UTC',
                sp_t                   => '',
                facet                  => undef,
                sectionItemsLimit      => 10,
            },
            extensions => {
                persistedQuery => {
                    version    => 1,
                    sha256Hash => $hash,
                },
            },
        }) };
        unless (defined $body) {
            $log->error("Client: pathfinderHome request body build failed: $@");
            $cb->(undef, { error => 'internal_error' });
            return;
        }

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                # Success callback -- parse JSON, defensively extract 37i9 IDs
                my $http    = shift;
                my $content = $http->content // '';
                my $result  = eval { from_json($content) };
                if ($@ || ref($result) ne 'HASH') {
                    $log->error("Client: pathfinderHome JSON parse error: $@");
                    $cb->(undef, { error => 'parse_error' });
                    return;
                }

                my ($ids, $degraded) = $class->_extractPathfinderIds($result);
                if ($degraded) {
                    main::INFOLOG && $log->info('Client: pathfinderHome degraded -- '
                        . 'errors[] in response (persisted-query hash rotation? Pitfall 4)');
                }

                # Per-user stable IDs (RESEARCH Specifics) -- only cache a
                # non-empty discovery so a transient degrade doesn't clobber
                # a previously known-good list.
                $cache->set("spoton_wp_mfy_ids_${accountId}", $ids, 3600)
                    if $accountId && @$ids;

                $cb->($ids, undef);
            },
            sub {
                # Error callback -- 429 (isolated WP pool), 401, generic
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;

                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 1   if $retryAfter < 1;
                    $retryAfter = 300 if $retryAfter > 300;

                    # Isolated Web-Player rate-limit key -- MUST NOT be
                    # 'spoton_rate_limit' (Pitfall 5, T-52-04).
                    $cache->set(WP_RATE_LIMIT_KEY, 1, $retryAfter);
                    $api429Count++;
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('warn', 'API', '429 on pathfinder/v2/query');
                    }
                    $log->warn("Client: pathfinderHome 429 rate limited for ${retryAfter}s (Web-Player pool)");
                    $cb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                if ($code == 401) {
                    $cache->remove("spoton_wp_token_${accountId}") if $accountId;
                    $log->warn('Client: pathfinderHome 401 unauthorized (Web-Player token invalidated)');
                    $cb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                # T-52-08: never log Authorization/client-token header values
                $log->error("Client: pathfinderHome HTTP $code error: $error");
                if ($INC{'Plugins/SpotOn/Status.pm'}) {
                    Plugins::SpotOn::Status->recordError('error', 'API', "HTTP $code for pathfinder/v2/query");
                }
                $cb->(undef, { error => $error, code => $code });
            },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        );

        # T-52-08: Authorization/client-token values are passed as headers
        # only -- never interpolated into a log line.
        $http->post(
            PATHFINDER_URL,
            'Authorization' => "Bearer $tokenHash->{access_token}",
            'client-token'  => ($tokenHash->{client_token} // ''),
            'Content-Type'  => 'application/json',
            'App-Platform'  => 'WebPlayer',
            $body,
        );
    });
}

# _extractPathfinderIds($class, $result)
# Defensive multi-level parse of a Pathfinder "home" GraphQL response body
# (A1, RESEARCH MEDIUM confidence -- the exact path was not verified against
# a live response in this phase; verify/refine with a captured fixture
# during UAT). Walks data.home.sectionContainer.sections.items[] ->
# sectionItems.items[] -> playlist URIs, keeps only spotify:playlist:37i9...,
# strips to the bare ID, and validates each ID against the same
# ^[A-Za-z0-9]{1,40}$ guard used throughout Client.pm (T-52-05, Security V5).
# Returns ($idsArrayRef, $degraded) in list context -- $degraded is true
# only when the response carries a top-level non-empty errors[] array
# (PersistedQueryNotFound-style failure, Pitfall 4). NEVER dies -- any shape
# mismatch at any level degrades to an empty list.
sub _extractPathfinderIds {
    my ($class, $result) = @_;
    my @ids;

    return (\@ids, 0) unless $result && ref($result) eq 'HASH';

    if (ref($result->{errors}) eq 'ARRAY' && @{$result->{errors}}) {
        return (\@ids, 1);
    }

    my $home = ($result->{data} && ref($result->{data}) eq 'HASH')
        ? $result->{data}->{home} : undef;
    return (\@ids, 0) unless $home && ref($home) eq 'HASH';

    my $sectionContainer = $home->{sectionContainer};
    return (\@ids, 0) unless $sectionContainer && ref($sectionContainer) eq 'HASH';

    my $sections = $sectionContainer->{sections};
    return (\@ids, 0) unless $sections && ref($sections) eq 'HASH';

    my $sectionList = $sections->{items};
    return (\@ids, 0) unless ref($sectionList) eq 'ARRAY';

    for my $section (@$sectionList) {
        next unless $section && ref($section) eq 'HASH';
        my $itemsWrapper = $section->{sectionItems};
        next unless $itemsWrapper && ref($itemsWrapper) eq 'HASH';
        my $items = $itemsWrapper->{items};
        next unless ref($items) eq 'ARRAY';

        for my $item (@$items) {
            next unless $item && ref($item) eq 'HASH';
            my $uri = _pathfinderItemUri($item);
            next unless defined $uri && !ref($uri);
            next unless $uri =~ /^spotify:playlist:(37i9[A-Za-z0-9]*)$/;
            my $id = $1;
            # T-52-05/Security V5: strict validation before the ID is ever
            # used to build a URL (copied guard from getPlaylistItems above).
            next unless $id =~ /^[A-Za-z0-9]{1,40}$/;
            push @ids, $id;
        }
    }

    return (\@ids, 0);
}

# _pathfinderItemUri($item)
# A1 (MEDIUM confidence): the exact nesting of the playlist URI within a
# sectionItems entry is unverified against a live response. Checks the most
# plausible shapes defensively; returns undef (never dies) on anything
# unexpected.
sub _pathfinderItemUri {
    my ($item) = @_;
    return $item->{uri} if defined $item->{uri} && !ref($item->{uri});
    for my $key (qw(content data)) {
        my $nested = $item->{$key};
        next unless $nested && ref($nested) eq 'HASH';
        return $nested->{uri} if defined $nested->{uri} && !ref($nested->{uri});
    }
    return undef;
}

# getWebPlayerPlaylistItems($class, $accountId, $playlistId, $params, $cb)
# Fetches paginated items for a Spotify-owned (37i9...) playlist
# (/playlists/{playlistId}/items) using the Web-Player bearer token instead
# of the PKCE token (D-07, Pitfall 3) -- Dev Mode returns 404 for ALL
# 37i9... playlists on the normal PKCE-token pipeline, even with a known
# valid ID. Mirrors getPlaylistItems above but:
#   - validates $playlistId up front (same ^[A-Za-z0-9]{1,40}$ guard, T-52-05)
#   - sources the bearer token from WebPlayer->getToken, NOT
#     TokenManager->getToken (D-07)
#   - uses the isolated WP_RATE_LIMIT_KEY pool so a Web-Player 429 never
#     sets the Browse spoton_rate_limit flag (Pitfall 5, T-52-04)
# Same pagination $params (offset/limit) shape as getPlaylistItems so the
# existing _fetchAllPages play-all helper can drive it unchanged.
sub getWebPlayerPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    $params ||= {};

    return $cb->(undef, { error => 'invalid_id' })
        unless $playlistId && $playlistId =~ /^[A-Za-z0-9]{1,40}$/;

    if ($cache->get(WP_RATE_LIMIT_KEY)) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    require Plugins::SpotOn::API::WebPlayer;
    Plugins::SpotOn::API::WebPlayer->getToken($accountId, sub {
        my ($tokenHash, $reason) = @_;
        unless ($tokenHash && $tokenHash->{access_token}) {
            main::INFOLOG && $log->info('Client: getWebPlayerPlaylistItems no Web-Player token (reason='
                . ($reason || 'unknown') . ')');
            $cb->(undef, { error => $reason || 'no_token' });
            return;
        }

        my $offset = $params->{offset} // 0;
        my $limit  = $params->{limit}  // 100;
        my $url    = API_BASE . "/playlists/$playlistId/items?offset=$offset&limit=$limit";

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http    = shift;
                my $content = $http->content // '';
                my $result;
                if ($content =~ /\S/) {
                    $result = eval { from_json($content) };
                    if ($@) {
                        $log->error("Client: getWebPlayerPlaylistItems JSON parse error: $@");
                        $cb->(undef, { error => 'parse_error' });
                        return;
                    }
                }
                $cb->($result);
            },
            sub {
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;

                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 1   if $retryAfter < 1;
                    $retryAfter = 300 if $retryAfter > 300;

                    # Isolated Web-Player rate-limit key -- MUST NOT be
                    # 'spoton_rate_limit' (Pitfall 5, T-52-04).
                    $cache->set(WP_RATE_LIMIT_KEY, 1, $retryAfter);
                    $api429Count++;
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('warn', 'API', "429 on WP playlists/$playlistId/items");
                    }
                    $log->warn("Client: getWebPlayerPlaylistItems 429 rate limited for ${retryAfter}s (Web-Player pool)");
                    $cb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                if ($code == 401) {
                    $cache->remove("spoton_wp_token_${accountId}") if $accountId;
                    $log->warn('Client: getWebPlayerPlaylistItems 401 unauthorized (Web-Player token invalidated)');
                    $cb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                $log->error("Client: getWebPlayerPlaylistItems HTTP $code error: $error");
                if ($INC{'Plugins/SpotOn/Status.pm'}) {
                    Plugins::SpotOn::Status->recordError('error', 'API', "HTTP $code for WP playlists/$playlistId/items");
                }
                $cb->(undef, { error => $error, code => $code });
            },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        );

        $http->get(
            $url,
            'Authorization' => "Bearer $tokenHash->{access_token}",
            'Accept'        => 'application/json',
        );
    });
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

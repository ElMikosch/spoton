package Plugins::SpotOn::API::Client;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape);

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
# Source: Spotty API.pm:18 (verifiziert: michaelherger/Spotty-Plugin/API.pm)

# Dual-token routing constants (D-01 through D-06)
# Source: Spotty-NG API.pm:93-98 adapted for SpotOn
use constant BUNDLED_HINT_TTL        => 86400;             # 24h hint persistence
use constant BUNDLED_HINT_KEY_PREFIX => 'spoton_bundled_hint_';
use constant SPOTON_DEFAULT_CLIENT_ID => '93aac68fb06348598c1e67734dfaceee';

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

# Module-level concurrency counter.
# Must be reset to 0 in Plugin.pm::initPlugin via Client->reset()
# to prevent stale counter after plugin reload (Pitfall 2 from RESEARCH.md).
my $inflightCount = 0;

# me/* family guard — ALWAYS checked first (D-05)
# Source: Spotty-NG API.pm:112
my $_meFamilyRegex = qr{^me(?:$|/|\?)};

# Deprecated-endpoint families for bundled-token fallback (D-04)
# Source: Spotty-NG API.pm:66-91 adapted
# These endpoints are removed/rate-limited under own Client-ID (dev mode restrictions).
my @KNOWN_DEPRECATED_FAMILIES = (
    qr{^browse/featured-playlists\b},
    qr{^browse/categories/[^/?]+/playlists\b},
    qr{^browse/categories\b},
    qr{^browse/new-releases\b},
    qr{^recommendations\b},
    qr{^users/[^/?]+/playlists\b},
    qr{^artists/[^/?]+/top-tracks\b},
    qr{^artists/[^/?]+/related-artists\b},
    qr{^playlists/37i9[A-Za-z0-9]+\b},  # Curated Spotify playlists (spoton_rate_limit_own / spoton_rate_limit_bundled)
);

# ============================================================
# Public class methods
# ============================================================

# reset($class)
# Resets the inflight counter. Called by Plugin.pm::initPlugin on startup.
sub reset {
    my ($class) = @_;
    $inflightCount = 0;
    main::INFOLOG && $log->info("Client: inflightCount reset to 0");
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
# limit defaults to 10 (Dev Mode max per NAV-11); offset is optional for pagination.
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'search', {
        _accountId => $accountId,
        q          => $params->{q} // '',
        type       => $params->{type}   // 'track,album,artist,playlist',
        limit      => $params->{limit}  // 10,
        offset     => $params->{offset} // 0,
    }, $cb);
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
    $class->_request('get', "artists/$artistId", { _accountId => $accountId }, $cb);
}

# getArtistAlbums($class, $accountId, $artistId, $params, $cb)
# Fetches albums for an artist (/artists/{artistId}/albums).
# Per D-09: include_groups takes a SINGLE value per call (album|single|compilation|appears_on).
# Combined values break pagination — callers issue separate requests per type.
sub getArtistAlbums {
    my ($class, $accountId, $artistId, $params, $cb) = @_;
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
    $class->_request('get', "albums/$albumId", { _accountId => $accountId }, $cb);
}

# getAlbumTracks($class, $accountId, $albumId, $params, $cb)
# Fetches paginated track list for an album (/albums/{albumId}/tracks).
# Offset-paginated; max limit 50.
sub getAlbumTracks {
    my ($class, $accountId, $albumId, $params, $cb) = @_;
    $class->_request('get', "albums/$albumId/tracks", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getPlaylistItems($class, $accountId, $playlistId, $params, $cb)
# Fetches paginated items for a playlist (/playlists/{playlistId}/items).
# Uses /items path — NOT /tracks (Pitfall 3: Feb 2026 rename).
# Offset-paginated; max limit 100.
sub getPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
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
# Dual-Token Pipeline (Phase 04.4):
#   0. Strip leading slash from path; compute $isMeFamily (D-05 me/* guard)
#   1. Per-flavor rate-limit check (D-01): own for me/*, bundled for others
#   2. Response cache check (unless _noCache) — cache key excludes flavor (API-03)
#   3. Concurrency cap (API-02) — defer via timer; cap is SHARED across both flavors
#   4. Increment inflight counter; wrap $cb in double-callback guard
#   5. Resolve start flavor via _resolveStartFlavor (D-04, D-05, D-06)
#   6. Dispatch to _doFlavouredRequest (may do bundled fallback on 403/410)
sub _request {
    my ($class, $method, $path, $params, $cb) = @_;

    # Step 0: Strip leading slash; compute me/* family membership (D-05)
    my $cleanPath = $path;
    $cleanPath =~ s{^/}{};
    my $isMeFamily = ($cleanPath =~ $_meFamilyRegex) ? 1 : 0;

    # Step 1: Resolve start flavor FIRST (D-04, D-05, D-06)
    # Flavor must be known before rate-limit check so we test the correct key (CR-03).
    my $startFlavor = $class->_resolveStartFlavor($cleanPath, $isMeFamily);

    # Step 2: Per-flavor rate-limit check (D-01, CR-02, CR-03)
    # Only check the per-flavor key for the resolved flavor — no global key (D-01).
    my $rlKey = ($startFlavor eq 'bundled') ? 'spoton_rate_limit_bundled' : 'spoton_rate_limit_own';
    if ($cache->get($rlKey)) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    # Step 3: Concurrency cap (API-02, Pitfall 6) — SHARED across both flavors.
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
    my $userCbCalled = 0;
    my $userCb = sub {
        return if $userCbCalled++;
        $inflightCount--;
        $cb->(@_);
    };

    # Step 6: Dispatch to flavor-aware request with optional bundled fallback
    $class->_doFlavouredRequest($method, $cleanPath, $params, $userCb, $startFlavor, 0, $isMeFamily);
}

# _resolveStartFlavor($class, $cleanPath, $isMeFamily)
# Determines the starting token flavor for a request.
# Priority: D-05 me/* guard > D-06 hint cache > D-03 degraded mode > D-04 own-first
# Source: Spotty-NG API.pm:1557-1590
sub _resolveStartFlavor {
    my ($class, $cleanPath, $isMeFamily) = @_;

    # D-05: me/* ALWAYS uses own-token — no fallback ever (hard guard)
    return 'own' if $isMeFamily;

    # D-06: Hint cache hit → skip own-token trial, go directly to bundled
    my $hintFlavor = $class->_lookupBundledHint($cleanPath);
    return 'bundled' if $hintFlavor;

    # D-03: Degraded mode — no own Client-ID configured → fall back to bundled
    my $hasOwnId = ($prefs->get('clientId') || SPOTON_DEFAULT_CLIENT_ID) ? 1 : 0;
    return $hasOwnId ? 'own' : 'bundled';
}

# _doFlavouredRequest($class, $method, $cleanPath, $params, $userCb, $flavor, $isRetry, $isMeFamily)
# Executes a single-flavor HTTP request with optional bundled fallback on 403/410/deprecated-404.
# Called from _request(); also called recursively for the bundled retry (isRetry=1).
# Source: Spotty-NG API.pm:1595-1703 adapted
sub _doFlavouredRequest {
    my ($class, $method, $cleanPath, $params, $userCb, $flavor, $isRetry, $isMeFamily) = @_;

    my $accountId = $params->{_accountId};

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->getToken($accountId, $flavor, sub {
        my $token = shift;

        unless ($token) {
            # T-04.4-01: log only flavor, not token value
            main::INFOLOG && $log->info("Client: no token available [flavor=$flavor] for account $accountId");
            $userCb->(undef, { error => 'no_token', flavor => $flavor });
            return;
        }

        $params->{_flavor} = $flavor;

        # Build URL and compute cache key with query params.
        # Cache key is built from path + sorted query string (CR-02).
        # CR-01: Include accountId to prevent multi-account cache contamination.
        # Note: cache key does NOT include flavor — response data is flavor-agnostic (API-03).
        my $url = API_BASE . "/$cleanPath";
        my @queryParts;
        for my $key (sort keys %{$params}) {
            next if $key =~ /^_/;
            push @queryParts, "$key=" . uri_escape($params->{$key});
        }
        my $queryStr = join('&', @queryParts);
        if ($queryStr) {
            $url .= '?' . $queryStr;
        }

        unless ($params->{_noCache}) {
            my $cacheKey = $queryStr
                ? "spoton_resp_${accountId}_${cleanPath}?${queryStr}"
                : "spoton_resp_${accountId}_${cleanPath}";
            $cacheKey .= "_locale=$params->{_locale}" if $params->{_locale};
            $params->{_cacheKey} = $cacheKey;
            if (my $cached = $cache->get($cacheKey)) {
                # Cache hit — $userCb decrements $inflightCount
                main::INFOLOG && $log->info("Client: cache hit for $cleanPath [flavor=$flavor]");
                $userCb->($cached);
                return;
            }
        }

        # T-02-10: Never log Authorization header value — only URL path, flavor, and method
        main::INFOLOG && $log->info("Client: $method $cleanPath [flavor=$flavor]");

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                # Success callback — parse JSON, cache, then check for bundled hint write
                my $http = shift;
                my $result = eval { from_json($http->content) };
                if ($@) {
                    $log->error("Client: JSON parse error for $cleanPath [flavor=$flavor]: $@");
                    $userCb->(undef, { error => 'parse_error' });
                    return;
                }

                # Cache response with domain-specific TTL (API-03).
                # Cache key excludes flavor — same data regardless of which token fetched it.
                unless ($params->{_noCache}) {
                    my $ttl = $class->_cacheTTL($cleanPath);
                    if ($ttl > 0) {
                        my $cacheKey = $params->{_cacheKey} || "spoton_resp_$cleanPath";
                        $cache->set($cacheKey, $result, $ttl);
                        main::INFOLOG && $log->info("Client: cached $cleanPath for ${ttl}s [flavor=$flavor]");
                    }
                }

                # D-06: If this was a successful bundled retry, persist hint for 24h
                # Anti-pattern prevention: only write hint on confirmed 2xx success
                if ($isRetry && $flavor eq 'bundled') {
                    $class->_rememberBundledHint($cleanPath);
                }

                $userCb->($result);
            },
            sub {
                # Error callback — handle 429, 401, 403/410 bundled fallback
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;
                if (!$code && $error && $error =~ /^(\d{3})\b/) {
                    $code = $1;
                }

                # D-01: Per-flavor rate-limit keys (spoton_rate_limit_own / spoton_rate_limit_bundled)
                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        # T-02-08: Cap Retry-After at 300s to prevent self-DoS
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 300 if $retryAfter > 300;

                    # Per-flavor rate-limit key only (D-01) — no global key (CR-02)
                    my $rlKey = ($flavor eq 'bundled')
                        ? 'spoton_rate_limit_bundled'
                        : 'spoton_rate_limit_own';
                    $cache->set($rlKey, 1, $retryAfter);
                    $log->warn("Client: 429 rate limited [flavor=$flavor] for ${retryAfter}s on $cleanPath");
                    $userCb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                # 401: Invalidate flavor-specific token cache
                if ($code == 401) {
                    $cache->remove("spoton_token_${accountId}_${flavor}") if $accountId;
                    $log->warn("Client: 401 unauthorized [flavor=$flavor] for $cleanPath (token invalidated)");
                    $userCb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                # D-06 bundled fallback: 403/410 on own-token for non-me/* paths
                # Also triggers on 404 if path is a known deprecated endpoint (Pitfall 4)
                # D-05: me/* NEVER falls back to bundled — hard guard
                # Anti-pattern: no re-entry into _request() (would re-run routing logic)
                if (!$isRetry && $flavor eq 'own' && !$isMeFamily
                        && ($code == 403 || $code == 410
                            || ($code == 404 && $class->_is404Deprecated($cleanPath)))) {
                    main::INFOLOG && $log->info(
                        "Client: $code on own-token for $cleanPath — retrying with bundled token");
                    $class->_doFlavouredRequest(
                        $method, $cleanPath, $params, $userCb, 'bundled', 1, $isMeFamily);
                    return;
                }

                # T-02-10: Log only status code and path, never token value
                $log->error("Client: HTTP $code error [flavor=$flavor] for $cleanPath: $error");
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

        $http->$method($url, @headers);
    });
}

# ============================================================
# Hint cache helpers (D-06)
# Source: Spotty-NG API.pm:93-98 adapted
# ============================================================

# _lookupBundledHint($class, $cleanPath)
# Returns 'bundled' if a cached hint exists for the path pattern, undef otherwise.
# Hint key: BUNDLED_HINT_KEY_PREFIX + md5_hex("$regex") — stable per family (Pitfall 5).
sub _lookupBundledHint {
    my ($class, $cleanPath) = @_;
    for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
        if ($cleanPath =~ $rx) {
            return 'bundled' if $cache->get(BUNDLED_HINT_KEY_PREFIX . md5_hex("$rx"));
        }
    }
    return undef;
}

# _rememberBundledHint($class, $cleanPath)
# Persists a 24h hint for the matched family pattern.
# Only written on confirmed 2xx bundled-retry success (never speculatively).
sub _rememberBundledHint {
    my ($class, $cleanPath) = @_;
    for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
        if ($cleanPath =~ $rx) {
            my $key = BUNDLED_HINT_KEY_PREFIX . md5_hex("$rx");
            $cache->set($key, 1, BUNDLED_HINT_TTL);
            main::INFOLOG && $log->info("Client: bundled hint cached for $cleanPath");
            return;
        }
    }
}

# _is404Deprecated($class, $cleanPath)
# Returns 1 if path matches a known deprecated-endpoint family (Pitfall 4).
# A real "not found" 404 should NOT trigger bundled fallback — only deprecated paths should.
sub _is404Deprecated {
    my ($class, $cleanPath) = @_;
    for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
        return 1 if $cleanPath =~ $rx;
    }
    return 0;
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

    # Library items: 60 seconds (tracks, albums, top, following, playlists)
    return 60 if $path =~ /^me\/(?:tracks|albums|top|following|playlists)/;

    # Track/album/artist metadata: 3600 seconds (1 hour)
    return 3600 if $path =~ /^(?:tracks|albums|artists)\//;

    # Search results: 300 seconds (5 minutes, same as browse tier)
    return 300 if $path =~ /^search/;

    # Playlists and browse data: 300 seconds (5 minutes)
    return 300 if $path =~ /^(?:playlists|browse)\//;

    # Default: no cache for unknown paths
    return 0;
}

1;

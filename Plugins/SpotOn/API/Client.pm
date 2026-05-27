package Plugins::SpotOn::API::Client;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Constants
use constant RATE_LIMIT_CACHE_KEY       => 'spoton_rate_limit_exceeded';
use constant RATE_LIMIT_DEFAULT_BACKOFF => 5;
use constant MAX_CONCURRENT_REQUESTS    => 3;
use constant API_BASE                   => 'https://api.spotify.com/v1';
use constant REQUEST_TIMEOUT            => 30;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

# Module-level concurrency counter.
# Must be reset to 0 in Plugin.pm::initPlugin via Client->reset()
# to prevent stale counter after plugin reload (Pitfall 2 from RESEARCH.md).
my $inflightCount = 0;

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
# Core request pipeline
# ============================================================

# _request($class, $method, $path, $params, $cb)
# Central HTTP egress point. All Spotify API calls go through here (API-01).
#
# Pipeline:
#   1. Rate limit flag check (cache key set on 429)
#   2. Response cache check (unless _noCache)
#   3. Concurrency cap — defer via timer if >= MAX_CONCURRENT_REQUESTS
#   4. Increment inflight counter
#   5. Token injection via TokenManager->getToken
#   6. Async HTTP call via SimpleAsyncHTTP
sub _request {
    my ($class, $method, $path, $params, $cb) = @_;

    # Step 1: Rate limit flag check (API-04)
    if ($cache->get(RATE_LIMIT_CACHE_KEY)) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    # Step 2: Response cache check (API-03) — skip for _noCache paths.
    # Cache key is built here only if it was pre-computed on a prior pass
    # (i.e. after query params are known). On first entry _cacheKey is undef
    # so we skip the check; on retry from the timer the key is already set.
    unless ($params->{_noCache}) {
        if (my $cacheKey = $params->{_cacheKey}) {
            if (my $cached = $cache->get($cacheKey)) {
                main::INFOLOG && $log->info("Client: cache hit for $path");
                $cb->($cached);
                return;
            }
        }
    }

    # Step 3: Concurrency cap (API-02) — FIFO defer via timer
    if ($inflightCount >= MAX_CONCURRENT_REQUESTS) {
        Slim::Utils::Timers::setTimer(
            undef,
            Time::HiRes::time() + 0.1,
            sub { $class->_request($method, $path, $params, $cb) }
        );
        return;
    }

    # Step 4: Increment inflight counter
    $inflightCount++;

    # Step 5: Token injection via TokenManager
    my $accountId = $params->{_accountId};
    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->getToken($accountId, sub {
        my $token = shift;

        unless ($token) {
            $inflightCount--;
            $cb->(undef, { error => 'no_token' });
            return;
        }

        # Step 6: Build URL and fire async HTTP request.
        # Append query params (excluding keys prefixed with _).
        # Build the cache key from path + sorted query string so that two
        # calls differing only in query params never share a cache entry (CR-02).
        my $url = API_BASE . "/$path";
        my @queryParts;
        for my $key (sort keys %{$params}) {
            next if $key =~ /^_/;
            push @queryParts, "$key=" . uri_escape($params->{$key});
        }
        my $queryStr = join('&', @queryParts);
        if ($queryStr) {
            $url .= '?' . $queryStr;
        }

        # Compute and cache the key so _onSuccess can use the same key.
        # Also perform the cache lookup now that we know the full key.
        unless ($params->{_noCache}) {
            my $cacheKey = $queryStr
                ? "spoton_resp_${path}?${queryStr}"
                : "spoton_resp_${path}";
            $params->{_cacheKey} = $cacheKey;
            if (my $cached = $cache->get($cacheKey)) {
                $inflightCount--;
                main::INFOLOG && $log->info("Client: cache hit for $path");
                $cb->($cached);
                return;
            }
        }

        # T-02-10: Never log Authorization header value — only URL path and status
        main::INFOLOG && $log->info("Client: $method $path");

        Slim::Networking::SimpleAsyncHTTP->new(
            sub { $class->_onSuccess(shift, $path, $params, $cb) },
            sub { $class->_onError(shift, $_[0], $path, $params, $cb) },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        )->$method(
            $url,
            'Authorization' => "Bearer $token",
            'Accept'        => 'application/json',
        );
    });
}

# _onSuccess($class, $http, $path, $params, $cb)
# Handles successful HTTP response: parse JSON, cache, invoke callback.
sub _onSuccess {
    my ($class, $http, $path, $params, $cb) = @_;

    $inflightCount--;

    my $result = eval { from_json($http->content) };
    if ($@) {
        $log->error("Client: JSON parse error for $path: $@");
        $cb->(undef, { error => 'parse_error' });
        return;
    }

    # Cache response with domain-specific TTL (API-03) unless _noCache or TTL=0.
    # Use the pre-computed _cacheKey that includes query params (CR-02).
    unless ($params->{_noCache}) {
        my $ttl = $class->_cacheTTL($path);
        if ($ttl > 0) {
            my $cacheKey = $params->{_cacheKey} || "spoton_resp_$path";
            $cache->set($cacheKey, $result, $ttl);
            main::INFOLOG && $log->info("Client: cached $path for ${ttl}s");
        }
    }

    $cb->($result);
}

# _onError($class, $http, $error, $path, $params, $cb)
# Handles HTTP error: handles 429 rate limiting, 401 token invalidation, other errors.
# CRITICAL: Both _onSuccess and _onError MUST decrement $inflightCount (Pitfall 2).
sub _onError {
    my ($class, $http, $error, $path, $params, $cb) = @_;

    $inflightCount--;

    my $code = ($http && $http->response) ? $http->response->code : 0;

    if ($code == 429) {
        # T-02-08: Cap Retry-After at 300 seconds to prevent self-DoS from malicious header
        my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
        if ($http && $http->response) {
            my $headerVal = $http->response->header('Retry-After');
            $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
        }
        $retryAfter = 300 if $retryAfter > 300;

        $cache->set(RATE_LIMIT_CACHE_KEY, 1, $retryAfter);
        $log->warn("Client: 429 rate limited for $retryAfter seconds");
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    if ($code == 401) {
        # Invalidate cached token for this account on 401 (token expired/revoked)
        my $accountId = $params->{_accountId} // '';
        $cache->remove("spoton_token_$accountId") if $accountId;
        $log->warn("Client: 401 unauthorized for $path (token invalidated for $accountId)");
        $cb->(undef, { error => 'unauthorized', code => 401 });
        return;
    }

    # T-02-10: Log only status code and path, never token value
    $log->error("Client: HTTP $code error for $path: $error");
    $cb->(undef, { error => $error, code => $code });
}

# _cacheTTL($path)
# Returns the appropriate cache TTL in seconds for a given API path.
# Based on CLAUDE.md domain-specific cache TTL guidelines.
sub _cacheTTL {
    my ($class, $path) = @_;

    # Playback state: never cache (always live)
    return 0 if $path =~ /^me\/player/;

    # User profile: always fresh
    return 0 if $path eq 'me';

    # Library items: 60 seconds
    return 60 if $path =~ /^me\/(?:tracks|albums)/;

    # Track/album/artist metadata: 3600 seconds (1 hour)
    return 3600 if $path =~ /^(?:tracks|albums|artists)\//;

    # Playlists and browse data: 300 seconds (5 minutes)
    return 300 if $path =~ /^(?:playlists|browse)\//;

    # Default: no cache for unknown paths
    return 0;
}

1;

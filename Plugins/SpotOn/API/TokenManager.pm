package Plugins::SpotOn::API::TokenManager;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url);
use Crypt::OpenSSL::Random;
use URI;
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Constants
use constant TOKEN_EXPIRY_BUFFER => 300;       # Refresh 5 min before expiry
use constant TOKEN_REFRESH_TIMER => 45 * 60;   # 45 minute proactive refresh cycle
use constant SPOTIFY_AUTH_URL    => 'https://accounts.spotify.com/authorize';
use constant SPOTIFY_TOKEN_URL   => 'https://accounts.spotify.com/api/token';
use constant SPOTIFY_ME_URL      => 'https://api.spotify.com/v1/me';
use constant REQUIRED_SCOPES     => join(' ', qw(
    user-read-playback-state
    user-modify-playback-state
    user-read-currently-playing
    user-read-recently-played
    user-read-private
    playlist-read-private
    user-library-read
    user-top-read
    streaming
));

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

# ============================================================
# Public class methods
# ============================================================

# getToken($class, $accountId, $cb)
# Checks cache first; falls back to refreshToken on miss.
# Interface preserved for Client.pm compatibility.
sub getToken {
    my ($class, $accountId, $cb) = @_;

    my $cached = $cache->get("spoton_token_$accountId");
    if (defined $cached) {
        main::INFOLOG && $log->info("TokenManager: cache hit for account $accountId");
        $cb->($cached);
        return;
    }

    $class->refreshToken($accountId, $cb);
}

# refreshToken($class, $accountId, $cb)
# Async PKCE refresh using stored refresh_token.
# On success: $cb->($accessToken). On failure: $cb->(undef).
sub refreshToken {
    my ($class, $accountId, $cb) = @_;

    my $accounts     = $prefs->get('accounts') || {};
    my $account      = $accounts->{$accountId} || {};
    my $refreshToken = $account->{refreshToken};
    my $clientId     = $prefs->get('clientId');

    unless ($refreshToken && $clientId) {
        $log->error("TokenManager: no refreshToken or clientId for account $accountId");
        $cb->(undef);
        return;
    }

    my $body_uri = URI->new('', 'https');
    $body_uri->query_form(
        grant_type    => 'refresh_token',
        refresh_token => $refreshToken,
        client_id     => $clientId,
    );
    my $body = $body_uri->query();

    # T-02.1-03: never log token values
    main::INFOLOG && $log->info("TokenManager: refreshing token for account $accountId");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http   = shift;
            my $result = eval { from_json($http->content) };
            if ($@ || !$result) {
                $log->error("TokenManager: JSON parse error on refresh for $accountId: $@");
                $cb->(undef);
                return;
            }
            unless ($result->{access_token}) {
                $log->error("TokenManager: no access_token in refresh response for $accountId");
                $cb->(undef);
                return;
            }

            # Update refresh_token if Spotify returns a new one (Pitfall 7)
            if ($result->{refresh_token}) {
                my $accts = $prefs->get('accounts') || {};
                $accts->{$accountId}{refreshToken} = $result->{refresh_token};
                $prefs->set('accounts', $accts);
                main::INFOLOG && $log->info("TokenManager: refresh token rotated for $accountId");
            }

            $class->_cacheToken($accountId, $result->{access_token}, $result->{expires_in});
            $cb->($result->{access_token});
        },
        sub {
            my ($http, $error) = @_;
            $log->error("TokenManager: refresh HTTP error for $accountId: $error");
            $cb->(undef);
        },
        { timeout => 30 }
    )->post(
        SPOTIFY_TOKEN_URL,
        'Content-Type' => 'application/x-www-form-urlencoded',
        $body,
    );
}

# startOAuthFlow($class, $clientId)
# Generates PKCE pair + state, caches PKCE data, builds Spotify auth URL.
# Returns ($authUrl, $state).
sub startOAuthFlow {
    my ($class, $clientId) = @_;

    my ($codeVerifier, $codeChallenge) = $class->_generatePkce();
    my $state       = $class->_generateState();
    my $redirectUri = $class->_buildRedirectUri();

    # T-02.1-06: cache verifier with TTL=600s; consume-on-use in callback
    $cache->set("spoton_pkce_$state", {
        code_verifier => $codeVerifier,
        client_id     => $clientId,
        redirect_uri  => $redirectUri,
    }, 600);

    my $uri = URI->new(SPOTIFY_AUTH_URL);
    $uri->query_form(
        response_type         => 'code',
        client_id             => $clientId,
        redirect_uri          => $redirectUri,
        code_challenge_method => 'S256',
        code_challenge        => $codeChallenge,
        scope                 => REQUIRED_SCOPES,
        state                 => $state,
    );

    return ($uri->as_string(), $state);
}

# exchangeCode($class, $code, $verifier, $clientId, $redirectUri, $cb)
# POSTs to SPOTIFY_TOKEN_URL to exchange authorization code for tokens.
# On success: $cb->($accountId, undef). On error: $cb->(undef, $error).
sub exchangeCode {
    my ($class, $code, $verifier, $clientId, $redirectUri, $cb) = @_;

    my $body_uri = URI->new('', 'https');
    $body_uri->query_form(
        grant_type    => 'authorization_code',
        code          => $code,
        redirect_uri  => $redirectUri,
        client_id     => $clientId,
        code_verifier => $verifier,
    );
    my $body = $body_uri->query();

    main::INFOLOG && $log->info("TokenManager: exchanging authorization code");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http   = shift;
            my $result = eval { from_json($http->content) };
            if ($@ || !$result) {
                $log->error("TokenManager: JSON parse error on code exchange: $@");
                $cb->(undef, "JSON parse error: $@");
                return;
            }
            # T-02.1-05: validate response contains access_token
            unless ($result->{access_token}) {
                my $err = $result->{error} || 'no access_token in response';
                $log->error("TokenManager: code exchange failed: $err");
                $cb->(undef, $err);
                return;
            }

            # Fetch user profile to generate stable accountId (D-12)
            $class->_fetchUserProfile($result->{access_token}, sub {
                my $profile = shift;
                unless ($profile && $profile->{id}) {
                    $log->error("TokenManager: could not fetch user profile after code exchange");
                    $cb->(undef, "Failed to fetch user profile");
                    return;
                }

                $class->_storeTokens(
                    $result->{access_token},
                    $result->{refresh_token},
                    $result->{expires_in},
                    $profile,
                    $cb
                );
            });
        },
        sub {
            my ($http, $error) = @_;
            $log->error("TokenManager: code exchange HTTP error: $error");
            $cb->(undef, $error);
        },
        { timeout => 30 }
    )->post(
        SPOTIFY_TOKEN_URL,
        'Content-Type' => 'application/x-www-form-urlencoded',
        $body,
    );
}

# removeAccount($class, $accountId)
# Removes account from prefs and cache. No filesystem cleanup.
sub removeAccount {
    my ($class, $accountId) = @_;

    # Remove from prefs
    my $accounts = $prefs->get('accounts') || {};
    delete $accounts->{$accountId};
    $prefs->set('accounts', $accounts);

    # Clear cached token
    $cache->remove("spoton_token_$accountId");

    # Clear active account if it was this one
    my $active = $prefs->get('activeAccount') || '';
    if ($active eq $accountId) {
        $prefs->set('activeAccount', '');
    }

    main::INFOLOG && $log->info("TokenManager: account $accountId removed");
}

# getAccountIds($class)
# Returns list of known account IDs.
sub getAccountIds {
    my ($class) = @_;
    my $accounts = $prefs->get('accounts') || {};
    return keys %{$accounts};
}

# getActiveAccountName($class, $client)
# Returns displayName of active account, or undef.
sub getActiveAccountName {
    my ($class, $client) = @_;

    my $activeId;
    if ($client) {
        $activeId = $prefs->client($client)->get('activeAccount');
    }
    $activeId ||= $prefs->get('activeAccount');

    return undef unless $activeId;

    my $accounts = $prefs->get('accounts') || {};
    return $accounts->{$activeId} ? $accounts->{$activeId}{displayName} : undef;
}

# refreshAllTokens($class)
# Refreshes tokens for all accounts and re-arms the 45-minute timer.
sub refreshAllTokens {
    my ($class) = @_;

    my @ids = $class->getAccountIds();
    for my $id (@ids) {
        $class->refreshToken($id, sub {
            my $token = shift;
            main::INFOLOG && $log->info("TokenManager: refreshed token for account $id")
                if $token;
            $log->error("TokenManager: failed to refresh token for account $id")
                unless $token;
        });
    }

    # Re-arm timer
    Slim::Utils::Timers::killTimers($class, \&refreshAllTokens);
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + TOKEN_REFRESH_TIMER,
        \&refreshAllTokens
    );
}

# ============================================================
# Private methods
# ============================================================

# _generatePkce()
# Returns ($code_verifier, $code_challenge).
# T-02.1-01: uses Crypt::OpenSSL::Random for cryptographic randomness
sub _generatePkce {
    my ($class) = @_;

    my $random_bytes  = Crypt::OpenSSL::Random::random_bytes(32);
    my $code_verifier = encode_base64url($random_bytes);
    $code_verifier    =~ s/=+$//;  # strip base64 padding per PKCE spec

    # SHA-256 of verifier, URL-safe base64 encoded
    my $code_challenge = encode_base64url(sha256($code_verifier));
    $code_challenge    =~ s/=+$//;

    return ($code_verifier, $code_challenge);
}

# _generateState()
# Returns random state string for OAuth CSRF protection.
# T-02.1-02: 16 random bytes -> URL-safe base64
sub _generateState {
    my ($class) = @_;

    my $raw   = Crypt::OpenSSL::Random::random_bytes(16);
    my $state = encode_base64url($raw);
    $state    =~ s/=+$//;
    return $state;
}

# _buildRedirectUri()
# Returns "http://127.0.0.1:{httpPort}/plugins/SpotOn/settings/callback".
# NEVER use serverURL() per RESEARCH.md Pitfall 5.
sub _buildRedirectUri {
    my ($class) = @_;
    my $httpPort = preferences('server')->get('httpport') || 9000;
    return "http://127.0.0.1:${httpPort}/plugins/SpotOn/settings/callback";
}

# _fetchUserProfile($class, $accessToken, $cb)
# GETs /me to retrieve {id, display_name}. Used to generate stable accountId.
# T-02.1-03: never logs the accessToken value
sub _fetchUserProfile {
    my ($class, $accessToken, $cb) = @_;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http    = shift;
            my $profile = eval { from_json($http->content) };
            if ($@ || !$profile) {
                $log->error("TokenManager: JSON parse error fetching user profile: $@");
                $cb->(undef);
                return;
            }
            $cb->($profile);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("TokenManager: HTTP error fetching user profile: $error");
            $cb->(undef);
        },
        { timeout => 30 }
    )->get(
        SPOTIFY_ME_URL,
        'Authorization' => "Bearer $accessToken",
        'Accept'        => 'application/json',
    );
}

# _storeTokens($class, $accessToken, $refreshToken, $expiresIn, $userProfile, $cb)
# Generates accountId from MD5 of Spotify user ID, stores tokens, calls $cb->($accountId).
# T-02.1-04: refresh_token in Prefs (not Cache) for persistence across restarts
sub _storeTokens {
    my ($class, $accessToken, $refreshToken, $expiresIn, $userProfile, $cb) = @_;

    # D-12: accountId from MD5 of spotify user_id (stable across username changes)
    my $spotifyUserId = $userProfile->{id} || '';
    my $accountId     = substr(md5_hex($spotifyUserId), 0, 8);
    my $displayName   = $userProfile->{display_name} || $spotifyUserId || 'Unknown';

    # Cache access token (short-lived)
    $class->_cacheToken($accountId, $accessToken, $expiresIn);

    # T-02.1-04: store refresh_token in Prefs (not Cache) for persistence
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} = {
        displayName  => $displayName,
        refreshToken => $refreshToken,
    };
    $prefs->set('accounts', $accounts);

    # Set as active account if none currently set
    unless ($prefs->get('activeAccount')) {
        $prefs->set('activeAccount', $accountId);
    }

    main::INFOLOG && $log->info("TokenManager: stored tokens for account $accountId ($displayName)");
    $cb->($accountId);
}

# _cacheToken($class, $accountId, $accessToken, $expiresIn)
# Caches the access token with TTL = expiresIn - TOKEN_EXPIRY_BUFFER.
# T-02.1-03: Never logs the token value itself.
sub _cacheToken {
    my ($class, $accountId, $accessToken, $expiresIn) = @_;

    $expiresIn //= 3600;
    my $ttl = $expiresIn > TOKEN_EXPIRY_BUFFER
        ? $expiresIn - TOKEN_EXPIRY_BUFFER
        : ($expiresIn > 60 ? $expiresIn : 60);

    $cache->set("spoton_token_$accountId", $accessToken, $ttl);
    main::INFOLOG && $log->info("TokenManager: token cached for account $accountId, TTL ${ttl}s");
}

1;

package Plugins::SpotOn::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Digest::MD5 qw(md5_hex);
use Encode qw(encode);
use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use URI;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::SpotOn::Helper;

use constant SETTINGS_URL => 'plugins/SpotOn/settings/basic.html';

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    require Slim::Web::Pages;

    # Register diagnostic bundle download endpoint (#3)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/diagnosticBundle',
        \&_diagnosticBundleHandler
    );

    # Register clear logs endpoint (GT-07)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/clearLogs',
        \&_clearLogsHandler
    );

    # Register PKCE OAuth endpoints (AUTH-01, AUTH-02)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/pkce/start',
        \&_pkceStartHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/pkce/callback',
        \&_pkceCallbackHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/pkce/manual',
        \&_pkceManualHandler
    );

    return $self;
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTON_NAME');
}

sub needsClient {
    return 0;
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs {
    # clientId is saved manually with sanitization in handler() — not listed here
    # to prevent Slim::Web::Settings::handler from overwriting with raw form input.
    return ($prefs, 'bitrate', 'binary', 'normalization', 'diagnosticMode');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    # Pass binary status to template
    $paramRef->{helperMissing} = string('PLUGIN_SPOTON_BINARY_MISSING') unless $helperPath;
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';
    $paramRef->{isMac}         = main::ISMAC ? 1 : 0;

    # D-08 Channel 2: Settings page re-auth warning banner — show when any
    # account needs re-authentication. Uses the LMS core $paramRef->{'warning'}
    # idiom, rendered automatically by the settings/header.html template.
    require Plugins::SpotOn::API::TokenManager;
    if (Plugins::SpotOn::API::TokenManager->anyAccountNeedsReauth()) {
        $paramRef->{'warning'} = string('PLUGIN_SPOTON_REAUTH_REQUIRED_SETTINGS');
    }

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        my $bitrate = $paramRef->{'pref_bitrate'} // 320;
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);

        # Save normalization pref (STR-08, T-04-05)
        # Checkbox: browser sends no value when unchecked — treat undef/empty as 0
        my $norm = $paramRef->{'pref_normalization'} ? 1 : 0;
        $prefs->set('normalization', $norm);

        # Normalization change flips passthrough mode (OGG↔PCM) — restart daemons
        # immediately so formatOverride() and daemon output stay in sync.
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();

        # Save Client-ID pref (D-02, T-04.4-01)
        # T-04.4-01: Input validation — alphanumeric only, max 32 chars.
        # Spotify Client-IDs are exactly 32 hex chars — regex + length check
        # eliminates shell metacharacter injection vectors for --client-id flag.
        if (defined $paramRef->{pref_clientId}) {
            my $id = $paramRef->{pref_clientId} // '';
            $id =~ s/[^a-zA-Z0-9]//g;  # T-04.4-01: alphanumeric only (injection guard)
            $id = substr($id, 0, 32);   # T-04.4-01: max 32 chars (Spotify Client-ID format)
            $prefs->set('clientId', $id);
        }

        # Account remove (CR-03, WR-03).
        # WR-03: validate that removeId is an 8-char hex string that actually
        # exists in the accounts pref before acting on it.  This prevents a
        # crafted POST with e.g. removeAccount=../../etc from reaching _cacheDir
        # and potentially deleting directories outside the SpotOn data dir.
        # CR-03: determine the new activeAccount BEFORE calling removeAccount,
        # because removeAccount clears activeAccount to '' before returning —
        # checking it afterwards would always yield '' and never auto-select a
        # replacement.
        if (my $removeId = $paramRef->{removeAccount}) {
            my $accounts = $prefs->get('accounts') || {};
            if (exists $accounts->{$removeId} && $removeId =~ /\A[0-9a-f]{8}\z/) {
                my $newActive;
                if (($prefs->get('activeAccount') || '') eq $removeId) {
                    # Removed account was active — pick a replacement from the
                    # remaining accounts (sorted for determinism).
                    my @remaining = sort grep { $_ ne $removeId } keys %{$accounts};
                    $newActive = @remaining ? $remaining[0] : '';
                }

                require Plugins::SpotOn::API::TokenManager;
                Plugins::SpotOn::API::TokenManager->removeAccount($removeId);

                # Apply the pre-computed replacement if one was needed.
                # (removeAccount already set activeAccount to '' if it was active;
                # we overwrite that '' with the proper replacement here.)
                if (defined $newActive) {
                    $prefs->set('activeAccount', $newActive);
                }

                # Clear per-client prefs pointing to the removed account so players
                # fall back to the new global. Prefs pointing to other accounts are
                # left intact (those per-client settings remain valid).
                for my $c (Slim::Player::Client::clients()) {
                    my $clientAcct = $prefs->client($c)->get('activeAccount') // '';
                    if ($clientAcct eq $removeId) {
                        $prefs->client($c)->remove('activeAccount');
                    }
                }
            }
        }

        # Account switch (WR-04).
        # Validate that switchId is a known account before setting it as active.
        # Without this check an attacker with a valid LMS session could set
        # activeAccount to an arbitrary string, which could confuse code that
        # reads the preference and assumes it points to a real account.
        if (my $switchId = $paramRef->{switchAccount}) {
            my $accounts = $prefs->get('accounts') || {};
            if (exists $accounts->{$switchId}) {
                $prefs->set('activeAccount', $switchId);
                # Clear per-client overrides for all connected players so they fall back
                # to the new global setting. _getAccountId() checks per-client first, so
                # without this, the Settings switch has no effect on players that already
                # have a per-client activeAccount pref set via the OPML account switcher.
                for my $c (Slim::Player::Client::clients()) {
                    $prefs->client($c)->remove('activeAccount');
                }
            }
        }

        # Save diagnosticMode (global pref, not per-player) (#3)
        my $diagMode = $paramRef->{'pref_diagnosticMode'} ? 1 : 0;
        $prefs->set('diagnosticMode', $diagMode);

        # Save global streamingMode default (COMPAT-01, GH #96 scope extension).
        # Deliberately NOT in the prefs() return list (see comment there) — validated
        # here and written directly so the base class handler cannot overwrite it
        # with unsanitized raw form input.
        if (defined $paramRef->{'pref_streamingMode'}) {
            my $mode = $paramRef->{'pref_streamingMode'};
            $mode = 'direct' unless $mode =~ /^(?:direct|proxy)$/;
            $prefs->set('streamingMode', $mode);
        }
    }

    my $serverPrefs = preferences('server');

    # Pass account data to template for all requests
    $paramRef->{accounts}         = $prefs->get('accounts') || {};
    $paramRef->{activeAccount}    = $prefs->get('activeAccount') || '';

    # Client-ID and degraded-mode status for template (D-02, D-03)
    $paramRef->{customClientId} = $prefs->get('clientId') || '';
    $paramRef->{degradedMode}   = _isDegradedMode();

    # PKCE auth status for template (AUTH-01): has any account completed the
    # PKCE OAuth flow (has a pkce_tokens.json)? Drives which setup guide/CTA
    # the template shows.
    $paramRef->{pkceConfigured} = _isPkceConfigured();

    # Diagnostic mode status for template (#3)
    $paramRef->{diagnosticEnabled} = $prefs->get('diagnosticMode') ? 1 : 0;

    # Global streaming mode default status for template (COMPAT-01, GH #96 scope extension)
    $paramRef->{globalStreamingMode} = $prefs->get('streamingMode') || 'direct';

    my $logTotal = 0;
    my $spotonDir = catdir($serverPrefs->get('cachedir'), 'spoton');
    for my $pattern ('*-connect.log', '*-unified.log') {
        for my $f (bsd_glob(catfile($spotonDir, $pattern))) {
            $logTotal += -s $f || 0;
        }
    }
    $paramRef->{connectLogSize} = $logTotal >= 1048576 ? sprintf('%.1f MB', $logTotal / 1048576)
                                : $logTotal >= 1024    ? sprintf('%.1f KB', $logTotal / 1024)
                                :                        "$logTotal B";

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

# ============================================================
# PKCE OAuth: /plugins/SpotOn/settings/pkce/start
# AJAX endpoint (AUTH-01, T-49-08). Generates a fresh code_verifier/challenge
# pair, stashes the verifier under a nonce (bridges this request to the
# later /pkce/callback or /pkce/manual request), and returns the Spotify
# authorization URL for the browser to open in a new tab. The verifier
# itself never leaves LMS (edge case A, urknall #176).
# ============================================================
sub _pkceStartHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::PKCE;

    my $clientId  = _pkceClientId();
    my $verifier  = Plugins::SpotOn::API::PKCE::generateCodeVerifier();
    my $challenge = Plugins::SpotOn::API::PKCE::generateCodeChallenge($verifier);

    # Nonce keys the one-time verifier cache and round-trips through the
    # state parameter across the GitHub Pages relay. It is not itself a
    # security boundary — the code_verifier is the actual OAuth proof.
    my $nonce = sprintf('%08x%08x', rand(2**32), rand(2**32));

    my $request = $response->request;
    my $host    = ($request && $request->header('Host')) || 'localhost';
    my $scheme  = ($request && $request->header('X-Forwarded-Proto')) || 'http';
    my $callbackUrl = $scheme . '://' . $host . '/plugins/SpotOn/settings/pkce/callback';

    my $state = Plugins::SpotOn::API::PKCE::buildState($callbackUrl, $nonce);
    Plugins::SpotOn::API::PKCE::storeVerifier($nonce, $verifier);

    my $authUrl = Plugins::SpotOn::API::PKCE::buildAuthorizationUrl($clientId, $challenge, $state);

    main::INFOLOG && $log->is_info && $log->info(
        "Settings: PKCE auth flow started [nonce=" . substr($nonce, 0, 8) . "...]");

    _jsonResponse($httpClient, $response, { url => $authUrl, nonce => $nonce });
}

# ============================================================
# PKCE OAuth: /plugins/SpotOn/settings/pkce/callback
# Browser redirect target (AUTH-01, AUTH-02) reached via the GitHub Pages
# relay after the user authorizes on accounts.spotify.com. This is a plain
# browser GET navigation, NOT an AJAX call — there is no X-Requested-With
# header to check, so it is intentionally exempt from _csrfCheck (T-49-09).
# Security instead comes from the one-time-use verifier cache: a request
# can only succeed once per /pkce/start call.
# ============================================================
sub _pkceCallbackHandler {
    my ($httpClient, $response) = @_;

    require Plugins::SpotOn::API::PKCE;

    my $request = $response->request;
    my %params  = $request ? $request->uri->query_form : ();

    if (my $err = $params{error}) {
        $log->warn("Settings: PKCE callback returned OAuth error: $err");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            string('PLUGIN_SPOTON_PKCE_ERROR'), 1);
        return;
    }

    my $code  = $params{code};
    my $state = $params{state};

    unless ($code) {
        $log->warn("Settings: PKCE callback missing authorization code");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            'No authorization code received.', 1);
        return;
    }

    my $verifier = _pkceLoadVerifierFromState($state);
    unless ($verifier) {
        $log->warn("Settings: PKCE callback — no verifier found for state (expired/reused)");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            'Authorization session expired or already used. Please try again from the Settings page.', 1);
        return;
    }

    my $clientId = _pkceClientId();

    Plugins::SpotOn::API::PKCE::exchangeCode($code, $clientId, $verifier, sub {
        my ($tokenData, $err) = @_;

        unless ($tokenData) {
            $log->error("Settings: PKCE token exchange failed: " . ($err || 'unknown'));
            _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                string('PLUGIN_SPOTON_PKCE_ERROR'), 1);
            return;
        }

        _pkceFinishAuth($httpClient, $response, $tokenData, $clientId, 0);
    });
}

# ============================================================
# PKCE OAuth: /plugins/SpotOn/settings/pkce/manual
# AJAX copy-paste fallback (edge case D, urknall #176) for when the browser
# auto-redirect from the GitHub Pages relay never reaches LMS (e.g. relay
# cannot resolve/reach a private-network LMS host from the user's phone).
# The pasted URL is only ever parsed for its code/state query parameters —
# it is never fetched or redirected to (T-49-10).
# ============================================================
sub _pkceManualHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::PKCE;

    my $callbackUrl = _postParam($response->request, 'callback_url');
    unless ($callbackUrl) {
        _jsonResponse($httpClient, $response, { status => 'error', message => 'No callback URL provided' });
        return;
    }

    my %params = eval { URI->new($callbackUrl)->query_form };
    if ($@ || !%params) {
        _jsonResponse($httpClient, $response, { status => 'error', message => 'Could not parse callback URL' });
        return;
    }

    my $code  = $params{code};
    my $state = $params{state};

    unless ($code && $state) {
        _jsonResponse($httpClient, $response,
            { status => 'error', message => 'Callback URL is missing code or state parameters' });
        return;
    }

    my $verifier = _pkceLoadVerifierFromState($state);
    unless ($verifier) {
        _jsonResponse($httpClient, $response,
            { status => 'error', message => 'Authorization session expired or already used' });
        return;
    }

    my $clientId = _pkceClientId();

    Plugins::SpotOn::API::PKCE::exchangeCode($code, $clientId, $verifier, sub {
        my ($tokenData, $err) = @_;

        unless ($tokenData) {
            $log->error("Settings: PKCE manual token exchange failed: " . ($err || 'unknown'));
            _jsonResponse($httpClient, $response, { status => 'error', message => 'Token exchange failed' });
            return;
        }

        _pkceFinishAuth($httpClient, $response, $tokenData, $clientId, 1);
    });
}

# ============================================================
# _pkceLoadVerifierFromState($state)
# Parses the state parameter and pops the matching verifier from the
# one-time-use cache. Returns undef (safely) on any malformed/missing input.
# ============================================================
sub _pkceLoadVerifierFromState {
    my ($state) = @_;
    return undef unless $state;

    my $stateData = Plugins::SpotOn::API::PKCE::parseState($state);
    my $nonce = $stateData ? $stateData->{nonce} : undef;
    return undef unless $nonce;

    return Plugins::SpotOn::API::PKCE::loadAndDeleteVerifier($nonce);
}

# ============================================================
# _pkceFinishAuth($httpClient, $response, $tokenData, $clientId, $isJson)
# Shared tail of the callback/manual handlers: looks up the Spotify user
# profile to derive a stable accountId, persists the PKCE tokens, and
# creates/updates the account in prefs. Responds with JSON (manual, AJAX
# fallback) or an HTML result page (callback, browser redirect).
# ============================================================
sub _pkceFinishAuth {
    my ($httpClient, $response, $tokenData, $clientId, $isJson) = @_;

    require Slim::Networking::SimpleAsyncHTTP;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http    = shift;
            my $profile = eval { from_json($http->content) };
            my $userId  = $profile && $profile->{id};
            unless ($userId) {
                $log->error("Settings: PKCE /me lookup returned no user ID — cannot create account");
                if ($isJson) {
                    _jsonResponse($httpClient, $response,
                        { status => 'error', message => 'Spotify profile lookup failed — please try again' });
                } else {
                    _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                        'Could not retrieve Spotify profile. Please try again.', 1);
                }
                return;
            }
            my $displayName = $profile->{display_name} || $userId;
            _pkceStoreAccount($httpClient, $response, $tokenData, $clientId, $userId, $displayName, $isJson);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("Settings: PKCE /me lookup failed: $error — cannot create account without user identity");
            if ($isJson) {
                _jsonResponse($httpClient, $response,
                    { status => 'error', message => 'Spotify profile lookup failed — please try again' });
            } else {
                _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                    'Could not retrieve Spotify profile. Please try again.', 1);
            }
        },
        { timeout => 30 }
    )->get(
        'https://api.spotify.com/v1/me',
        'Authorization' => "Bearer $tokenData->{access_token}",
        'Accept'        => 'application/json',
    );
}

# ============================================================
# _pkceStoreAccount(...)
# Derives accountId, persists PKCE tokens (chmod 0600 file via PKCE.pm),
# secures the account directory (chmod 0700, T-04.3-07 pattern), and stores
# the account in prefs via TokenManager's existing _storeAccountPrefs (sets
# activeAccount + triggers daemon start if this is the first account).
# ============================================================
sub _pkceStoreAccount {
    my ($httpClient, $response, $tokenData, $clientId, $userId, $displayName, $isJson) = @_;

    my $accountId = substr(md5_hex($userId), 0, 8);
    my $expiresAt = time() + ($tokenData->{expires_in} || 3600);

    require Plugins::SpotOn::API::PKCE;
    my $stored = Plugins::SpotOn::API::PKCE::storeTokens($accountId, {
        access_token  => $tokenData->{access_token},
        refresh_token => $tokenData->{refresh_token},
        expires_at    => $expiresAt,
        client_id     => $clientId,
        scope         => $tokenData->{scope},
    });

    unless ($stored) {
        $log->error("Settings: PKCE token storage failed for account $accountId — aborting account creation");
        if ($isJson) {
            _jsonResponse($httpClient, $response, { status => 'error', message => 'Token storage failed' });
        } else {
            _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                'Token storage failed — check disk space and cache directory permissions.', 1);
        }
        return;
    }

    my $serverPrefs = preferences('server');
    my $accountDir  = catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
    chmod(0700, $accountDir) if -d $accountDir;

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->_storeAccountPrefs($accountId, $userId, $displayName, sub {
        main::INFOLOG && $log->is_info && $log->info(
            "Settings: PKCE account $accountId connected (displayName=$displayName)");

        # T-50-11: clear the persistent needsReauth flag immediately on a
        # successful (re-)authentication rather than waiting for the next
        # refresh timer cycle.
        Plugins::SpotOn::API::TokenManager->clearNeedsReauth($accountId);

        if ($isJson) {
            _jsonResponse($httpClient, $response, { status => 'ok', accountId => $accountId });
        } else {
            _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_SUCCESS'),
                string('PLUGIN_SPOTON_PKCE_SUCCESS'), 0);
        }
    });
}

# ============================================================
# _pkceClientId()
# Resolves the Client-ID to use for PKCE requests: the user's own Spotify
# Developer App Client-ID if configured, otherwise SpotOn's bundled default
# (same fallback logic as the rest of the codebase, e.g. TokenManager.pm).
# ============================================================
sub _pkceClientId {
    my $custom = $prefs->get('clientId');
    return $custom if $custom;

    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client::SPOTON_DEFAULT_CLIENT_ID();
}

# ============================================================
# _isPkceConfigured()
# True if any known account has completed the PKCE OAuth flow (has a
# pkce_tokens.json). Drives which setup guide/CTA the template shows.
# ============================================================
sub _isPkceConfigured {
    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::API::PKCE;

    for my $id (Plugins::SpotOn::API::TokenManager->getAccountIds()) {
        return 1 if Plugins::SpotOn::API::PKCE::loadTokens($id);
    }
    return 0;
}

# ============================================================
# _postParam($request, $key)
# Extracts a single application/x-www-form-urlencoded POST body parameter.
# Returns undef if the request/body is missing or the key is absent.
# ============================================================
sub _postParam {
    my ($request, $key) = @_;
    return undef unless $request;

    my $body = $request->content;
    return undef unless defined $body && length $body;

    my %params = eval { URI->new("?$body")->query_form };
    return undef if $@;
    return $params{$key};
}

# ============================================================
# _htmlEscape($str)
# Minimal HTML entity escaping for values interpolated into
# _renderPkceResultPage — the OAuth 'error' query parameter is attacker/
# Spotify controlled and must not be reflected unescaped (Rule 2, XSS).
# ============================================================
sub _htmlEscape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# ============================================================
# _renderPkceResultPage($httpClient, $response, $title, $message, $isError)
# Renders a minimal centered-card HTML result page for the /pkce/callback
# browser redirect flow. Success pages meta-refresh back to Settings after
# 3 seconds; error pages show a link back to Settings instead (the user may
# need to read the error before leaving).
# ============================================================
sub _renderPkceResultPage {
    my ($httpClient, $response, $title, $message, $isError) = @_;

    my $safeTitle   = _htmlEscape($title);
    my $safeMessage = _htmlEscape($message);
    my $settingsUrl = '/' . SETTINGS_URL;

    my $action = $isError
        ? qq{<p><a href="$settingsUrl">} . _htmlEscape(string('PLUGIN_SPOTON_NAME')) . qq{</a></p>}
        : qq{<meta http-equiv="refresh" content="3;url=$settingsUrl">};

    my $html = qq{<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$safeTitle</title>
$action
<style>
  body { font-family: -apple-system, Helvetica, Arial, sans-serif; background: #191414;
         color: #fff; display: flex; align-items: center; justify-content: center;
         min-height: 100vh; margin: 0; }
  .card { background: #282828; border-radius: 12px; padding: 2em 2.5em; max-width: 420px;
          text-align: center; }
  a { color: #1db954; }
</style>
</head>
<body>
  <div class="card">
    <h2>$safeTitle</h2>
    <p>$safeMessage</p>
  </div>
</body>
</html>
};

    my $bytes = encode('UTF-8', $html);
    $response->header('Content-Length' => length($bytes));
    $response->code($isError ? 400 : 200);
    $response->header('Connection' => 'close');
    $response->content_type('text/html; charset=utf-8');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

# ============================================================
# Diagnostic bundle endpoint (#3): /plugins/SpotOn/settings/diagnosticBundle
# Returns a downloadable text file with system info + daemon logs.
# Only works when diagnosticMode pref is enabled (403 otherwise).
# ============================================================
sub _diagnosticBundleHandler {
    my ($httpClient, $response) = @_;

    unless ($prefs->get('diagnosticMode')) {
        _jsonResponse($httpClient, $response, { error => 'Diagnostic mode not enabled' }, 403);
        return;
    }

    my $serverPrefs = preferences('server');
    my $spotonDir   = catdir($serverPrefs->get('cachedir'), 'spoton');

    # Collect all daemon logs (connect + unified)
    my @logFiles = (
        bsd_glob(catfile($spotonDir, '*-connect.log')),
        bsd_glob(catfile($spotonDir, '*-unified.log')),
    );

    # Build header with system info
    my $activeId = $prefs->get('activeAccount') || '';
    my $redactedId = $activeId ? substr($activeId, 0, 4) . '****' : 'none';
    my $clientId = $prefs->get('clientId') || '';
    my $redactedClientId = $clientId ? substr($clientId, 0, 4) . '****' : 'none';

    my @playerList;
    for my $c (Slim::Player::Client::clients()) {
        push @playerList, sprintf('  %s | %s | %s', $c->name, $c->id, $c->model);
    }

    require POSIX;
    my $timestamp = POSIX::strftime('%Y%m%d-%H%M%S', localtime);

    my $header = join("\n",
        '=== SpotOn Diagnostic Bundle ===',
        "Generated: $timestamp",
        '',
        '--- System Info ---',
        "LMS version: $::VERSION",
        "OS: $^O",
        "Perl: $]",
        "SpotOn version: " . (Plugins::SpotOn::Plugin->_pluginDataFor('version') || 'unknown'),
        "Active account: $redactedId",
        "Bitrate: " . ($prefs->get('bitrate') || 320),
        "Normalization: " . ($prefs->get('normalization') ? 'on' : 'off'),
        "Client-ID: $redactedClientId",
        "diagnosticMode: 1",
        '',
        '--- Players ---',
        (@playerList ? join("\n", @playerList) : '  (none)'),
        '',
        '=' x 50,
        '',
    );

    # --- Token & API Status ---
    my @tokenStatus;
    eval {
        require Plugins::SpotOn::API::Client;
        my $snapshot = Plugins::SpotOn::API::Client->statusSnapshot() || {};
        push @tokenStatus, '--- Token & API Status ---';

        my $accounts = $prefs->get('accounts') || {};
        my $displayName = 'unknown';
        if ($activeId && $accounts->{$activeId}) {
            $displayName = $accounts->{$activeId}{displayName} || $accounts->{$activeId}{spotifyUserId} || 'unknown';
        }
        push @tokenStatus, "  Display name: $displayName";
        push @tokenStatus, "  API requests: " . ($snapshot->{apiRequestCount} || 0);
        push @tokenStatus, "  429 responses: " . ($snapshot->{api429Count} || 0);
        push @tokenStatus, "  Rate limited: " . ($snapshot->{rateLimited} ? 'YES' : 'no');

        if ($INC{'Plugins/SpotOn/Status.pm'}) {
            my $errors = Plugins::SpotOn::Status->getErrorHistory() || [];
            my @tokenErrors = grep { $_->{module} && $_->{module} eq 'Token' } @$errors;
            if (@tokenErrors) {
                push @tokenStatus, '';
                push @tokenStatus, '  Recent token errors (' . scalar(@tokenErrors) . '):';
                for my $err (@tokenErrors[0 .. ($#tokenErrors > 9 ? 9 : $#tokenErrors)]) {
                    my $ts = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime($err->{ts}));
                    push @tokenStatus, "    [$ts] $err->{message}";
                }
            } else {
                push @tokenStatus, '  Recent token errors: (none)';
            }
        }
    };
    if ($@) {
        @tokenStatus = ('--- Token & API Status ---');
        push @tokenStatus, "  (could not collect: $@)";
    }
    $header .= join("\n", @tokenStatus) . "\n\n";

    # Append each log file (cap at 500KB per file)
    my $maxBytes = 500 * 1024;
    my $logs = '';
    for my $logFile (@logFiles) {
        my $basename = basename($logFile);
        $logs .= "--- Log: $basename ---\n";
        $logs .= _readLogTail($logFile, $maxBytes);
        $logs .= "\n";
    }

    if (!@logFiles) {
        $logs = "--- No daemon log files found ---\n";
    }

    # Extract SpotOn-related lines from LMS server.log
    my $logdir = $serverPrefs->get('logdir');
    my $serverLogFile = $logdir ? catfile($logdir, 'server.log') : undef;
    if ($serverLogFile && -f $serverLogFile) {
        $logs .= "--- LMS server.log (SpotOn entries, last 200) ---\n";
        if (open(my $sfh, '<', $serverLogFile)) {
            my @spotonLines;
            while (my $line = <$sfh>) {
                push @spotonLines, $line if $line =~ /SpotOn|spoton/i;
                shift @spotonLines if @spotonLines > 200;
            }
            close $sfh;
            $logs .= join('', @spotonLines) || "(no SpotOn entries found)\n";
        } else {
            $logs .= "(could not open server.log: $!)\n";
        }
        $logs .= "\n";
    }

    my $content = $header . $logs;
    my $filename = "spoton-diag-$timestamp.txt";

    my $bytes = encode('UTF-8', $content);
    $response->header('Content-Length' => length($bytes));
    $response->code(200);
    $response->header('Connection' => 'close');
    $response->content_type('text/plain; charset=utf-8');
    $response->header('Content-Disposition' => "attachment; filename=\"$filename\"");
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

# ============================================================
# Clear logs endpoint (GT-07): /plugins/SpotOn/settings/clearLogs
# Deletes all *-connect.log files in the spoton cache directory.
# ============================================================
sub _clearLogsHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    my $serverPrefs = preferences('server');
    my $spotonDir   = catdir($serverPrefs->get('cachedir'), 'spoton');
    # W1: bsd_glob — plain glob() splits on whitespace (fails for paths with spaces)
    my @logFiles = (
        bsd_glob(catfile($spotonDir, '*-connect.log')),
        bsd_glob(catfile($spotonDir, '*-unified.log')),
    );

    my $deleted = 0;
    for my $logFile (@logFiles) {
        if (unlink $logFile) {
            $deleted++;
        } else {
            $log->warn("clearLogs: failed to delete $logFile: $!");
        }
    }

    main::INFOLOG && $log->is_info && $log->info("clearLogs: deleted $deleted log file(s)");

    _jsonResponse($httpClient, $response, { status => 'ok', deleted => $deleted });
}

sub _jsonResponse {
    my ($httpClient, $response, $data, $code) = @_;
    $code //= 200;
    my $bytes = encode('UTF-8', to_json($data));
    $response->header('Content-Length' => length($bytes));
    $response->code($code);
    $response->header('Connection' => 'close');
    $response->content_type('application/json');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

# ============================================================
# Helper: check degraded mode (D-03)
# Degraded = no custom Client-ID configured.
# Shows a hint in Settings so the user can enter their own Spotify Developer App.
# ============================================================
sub _isDegradedMode {
    my $customId = $prefs->get('clientId') || '';
    return $customId ? 0 : 1;
}

sub _readLogTail {
    my ($path, $maxBytes) = @_;
    if (open my $fh, '<', $path) {
        my $size = -s $path;
        my $content = '';
        if ($size > $maxBytes) {
            seek($fh, -$maxBytes, 2);
            <$fh>;
            $content .= "[...truncated to last 500KB...]\n";
        }
        local $/;
        $content .= <$fh> // '';
        close $fh;
        return $content;
    }
    return "(could not read " . basename($path) . ": $!)\n";
}

# ============================================================
# CSRF guard for write endpoints (P-CR-03)
# addRawFunction handlers bypass LMS's built-in CSRF protection
# (Slim::Web::HTTP dispatches raw functions before CSRF check on line 512).
# This guard validates X-Requested-With: XMLHttpRequest for write endpoints
# when LMS has csrfProtectionLevel enabled.
# Read-only endpoints (discoveryStatus, diagnosticBundle) are not guarded.
# ============================================================
sub _csrfCheck {
    my ($httpClient, $response) = @_;

    my $serverPrefs = preferences('server');
    return 1 unless $serverPrefs->get('csrfProtectionLevel');

    my $request = $response->request;
    return 1 if $request
        && $request->header('X-Requested-With')
        && $request->header('X-Requested-With') eq 'XMLHttpRequest';

    $response->code(403);
    $response->header('Content-Length' => 0);
    $response->header('Connection' => 'close');
    $response->content_type('text/plain');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'');
    return 0;
}

1;

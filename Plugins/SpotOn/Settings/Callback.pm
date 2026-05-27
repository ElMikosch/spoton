package Plugins::SpotOn::Settings::Callback;

# OAuth callback route handler.
# Receives Spotify's redirect after user authentication, validates the OAuth
# state parameter for CSRF protection (T-02.1-02), exchanges the authorization
# code for tokens via TokenManager->exchangeCode, and renders a success or
# error result page inline.
#
# This is a plain package — NOT a Slim::Web::Settings subclass.
# Per RESEARCH.md Pitfall 6, do NOT use protectURI: Spotify's redirect carries
# no LMS CSRF token; the state parameter IS the CSRF protection.

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Web::Pages;

use constant CALLBACK_PATH => 'plugins/SpotOn/settings/callback';

my $log   = logger('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

# ============================================================
# Public class methods
# ============================================================

# init()
# Registers the OAuth callback route with the LMS web server.
# Must be called from Plugin.pm initPlugin() inside the WEBUI guard.
sub init {
    Slim::Web::Pages->addPageFunction(CALLBACK_PATH, \&handler);
    main::INFOLOG && $log->info("Callback: OAuth callback route registered at " . CALLBACK_PATH);
}

# handler($client, $paramRef, $callback, $httpClient, $response)
# LMS page function handler — plain sub, NOT a class method (no $class first arg).
# Receives Spotify's redirect with ?code=&state= or ?error=.
# Validates state, exchanges code for tokens, renders success or error HTML.
#
# T-02.1-09: Never log $paramRef->{code} value.
sub handler {
    my ($client, $paramRef, $callback, $httpClient, $response) = @_;

    my $code  = $paramRef->{code}  // '';
    my $state = $paramRef->{state} // '';
    my $error = $paramRef->{error} // '';

    # Error path: user denied or Spotify returned an error
    if ($error) {
        main::INFOLOG && $log->info("Callback: Spotify returned error: $error");
        _renderResult($client, $paramRef, $callback, $httpClient, $response, 0, $error);
        return;
    }

    # T-02.1-02: Validate state against cache (CSRF protection)
    # State must match a prior startOAuthFlow — rejects injected or replayed codes
    my $pkce = $cache->get("spoton_pkce_$state");
    unless (defined $pkce) {
        # State not found: expired (>600s), already consumed, or forged
        main::INFOLOG && $log->info("Callback: state validation failed (state prefix: "
            . substr($state, 0, 8) . "...)");
        _renderResult($client, $paramRef, $callback, $httpClient, $response, 0, 'invalid_state');
        return;
    }

    # T-02.1-02: Consume state immediately — prevents replay attacks
    $cache->remove("spoton_pkce_$state");
    main::INFOLOG && $log->info("Callback: state validated and consumed (state prefix: "
        . substr($state, 0, 8) . "...)");

    # Exchange authorization code for tokens via TokenManager (async, non-blocking)
    # T-02.1-09: $code is NOT logged here or inside exchangeCode
    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->exchangeCode(
        $code,
        $pkce->{code_verifier},
        $pkce->{client_id},
        $pkce->{redirect_uri},
        sub {
            my ($accountId, $err) = @_;
            # exchangeCode calls $cb with ($accountId, undef) on success
            # or (undef, $errorString) on failure
            if (defined $accountId) {
                main::INFOLOG && $log->info(
                    "Callback: token exchange succeeded for account $accountId");
                _renderResult($client, $paramRef, $callback, $httpClient, $response, 1, undef);
            } else {
                $log->error("Callback: token exchange failed: " . ($err // 'unknown error'));
                _renderResult($client, $paramRef, $callback, $httpClient, $response, 0, $err);
            }
        }
    );

    # Return undef to signal async response to the LMS web server
    return;
}

# ============================================================
# Private helpers
# ============================================================

# _renderResult($client, $paramRef, $callback, $httpClient, $response, $success, $errorMsg)
# Builds and delivers an HTML response inline.
# Success path: "Erfolgreich verbunden!" with auto-redirect to settings after 2s.
# Error path: "Verbindung fehlgeschlagen" with error message and back link.
# Per UI-SPEC.md Screen 3.
sub _renderResult {
    my ($client, $paramRef, $callback, $httpClient, $response, $success, $errorMsg) = @_;

    $response->content_type('text/html');

    # Determine the settings page URL for redirect / back link
    # webroot is provided by LMS in paramRef for page functions; default to '/' as fallback
    my $webroot      = $paramRef->{webroot} // '/';
    my $settingsUrl  = $webroot . 'settings/plugin/spoton.html';

    my $html;
    if ($success) {
        $html = <<"HTML";
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>SpotOn - Verbunden</title>
</head>
<body style="font-family:sans-serif;padding:24px">
<h2 style="color:green">Erfolgreich verbunden!</h2>
<p>Du wirst gleich zu den Einstellungen weitergeleitet...</p>
<script>
setTimeout(function() {
    window.location = "$settingsUrl";
}, 2000);
</script>
</body>
</html>
HTML
    } else {
        my $safeError = _html_escape($errorMsg // 'Unbekannter Fehler');
        $html = <<"HTML";
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>SpotOn - Verbindungsfehler</title>
</head>
<body style="font-family:sans-serif;padding:24px">
<h2 style="color:red">Verbindung fehlgeschlagen</h2>
<p style="color:red">$safeError</p>
<p><a href="$settingsUrl">Zurueck zu den Einstellungen</a></p>
</body>
</html>
HTML
    }

    $callback->($client, $paramRef, \$html, $httpClient, $response);
    return;
}

# _html_escape($str)
# Escapes HTML special characters to prevent XSS in error messages.
sub _html_escape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

1;

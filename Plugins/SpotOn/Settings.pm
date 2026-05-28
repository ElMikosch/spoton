package Plugins::SpotOn::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::SpotOn::Helper;

use constant SETTINGS_URL => 'plugins/SpotOn/settings/basic.html';

my $prefs = preferences('plugin.spoton');

sub new {
    my $class = shift;
    return $class->SUPER::new(@_);
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTON_NAME');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs {
    return ($prefs, 'bitrate', 'binary', 'clientId', 'normalization');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    require Plugins::SpotOn::API::TokenManager;

    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    # Binary-Status an Template uebergeben
    $paramRef->{helperMissing} = string('PLUGIN_SPOTON_BINARY_MISSING') unless $helperPath;
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        my $bitrate = $paramRef->{'pref_bitrate'};
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);

        # Normalization pref speichern (STR-08, T-04-05)
        # Checkbox: wenn nicht angehakt, sendet Browser keinen Wert — undef/leer wird zu 0
        my $norm = $paramRef->{'pref_normalization'} ? 1 : 0;
        $prefs->set('normalization', $norm);

        # OAuth PKCE flow initiation (D-07).
        # LMS loads settings pages inside an iframe, so a 302 redirect would
        # try to load accounts.spotify.com inside the frame — blocked by
        # Spotify's X-Frame-Options. Instead, generate the auth URL and pass
        # it to the template, which opens it in a new tab via target="_blank".
        if ($paramRef->{startOAuth}) {
            my $clientId = $paramRef->{'pref_clientId'} // '';
            $clientId =~ s/^\s+|\s+$//g;
            $prefs->set('clientId', $clientId) if $clientId;
            if (!$clientId) {
                $paramRef->{oauthError} = string('PLUGIN_SPOTON_CLIENT_ID_REQUIRED');
            } else {
                my ($authUrl, $state) = Plugins::SpotOn::API::TokenManager->startOAuthFlow($clientId);
                if ($authUrl) {
                    $paramRef->{authUrl} = $authUrl;
                } else {
                    $paramRef->{oauthError} = string('PLUGIN_SPOTON_AUTH_ERROR');
                }
            }
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

                Plugins::SpotOn::API::TokenManager->removeAccount($removeId);

                # Apply the pre-computed replacement if one was needed.
                # (removeAccount already set activeAccount to '' if it was active;
                # we overwrite that '' with the proper replacement here.)
                if (defined $newActive) {
                    $prefs->set('activeAccount', $newActive);
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
            }
        }
    }

    # Pass account and OAuth data to template for all requests
    $paramRef->{accounts}      = $prefs->get('accounts') || {};
    $paramRef->{activeAccount} = $prefs->get('activeAccount') || '';
    $paramRef->{clientId}      = $prefs->get('clientId') || '';
    $paramRef->{redirectUri}   = Plugins::SpotOn::API::TokenManager->buildRedirectUri();

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;

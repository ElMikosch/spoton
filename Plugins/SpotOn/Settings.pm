package Plugins::SpotOn::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;

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

    # Register AJAX discoveryStatus endpoint (addRawFunction pattern from Spotty/Settings/Auth.pm)
    require Slim::Web::Pages;
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/discoveryStatus',
        \&_discoveryStatusHandler
    );

    return $self;
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTON_NAME');
}

sub needsClient {
    return 1;
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs {
    # clientId is saved manually with sanitization in handler() — not listed here
    # to prevent Slim::Web::Settings::handler from overwriting with raw form input.
    return ($prefs, 'bitrate', 'binary', 'normalization');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    # Binary-Status an Template uebergeben
    $paramRef->{helperMissing} = string('PLUGIN_SPOTON_BINARY_MISSING') unless $helperPath;
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        my $bitrate = $paramRef->{'pref_bitrate'} // 320;
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);

        # Normalization pref speichern (STR-08, T-04-05)
        # Checkbox: wenn nicht angehakt, sendet Browser keinen Wert — undef/leer wird zu 0
        my $norm = $paramRef->{'pref_normalization'} ? 1 : 0;
        $prefs->set('normalization', $norm);

        # Client-ID pref speichern (D-02, T-04.4-01)
        # T-04.4-01: Input-Validierung — nur alphanumerische Zeichen, max 32 Zeichen.
        # Spotify Client-IDs sind genau 32 hex-Zeichen — regex + Laengencheck
        # eliminiert Shell-Metacharacter-Injection-Vektoren fuer --client-id Flag.
        if (defined $paramRef->{pref_clientId}) {
            my $id = $paramRef->{pref_clientId} // '';
            $id =~ s/[^a-zA-Z0-9]//g;  # T-04.4-01: nur alphanumerisch (Injection-Schutz)
            $id = substr($id, 0, 32);   # T-04.4-01: max 32 Zeichen (Spotify Client-ID-Format)
            $prefs->set('clientId', $id);
        }

        # ZeroConf Discovery starten (D-01)
        # Use 'defined' — submit button value may be empty string when strings aren't loaded
        if (defined $paramRef->{startDiscovery}) {
            require Plugins::SpotOn::API::TokenManager;
            Plugins::SpotOn::API::TokenManager->startDiscovery();
        }

        # ZeroConf Discovery stoppen
        if (defined $paramRef->{stopDiscovery}) {
            require Plugins::SpotOn::API::TokenManager;
            Plugins::SpotOn::API::TokenManager->stopDiscovery();
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

        # Per-player Connect toggle (D-10, CON-10, T-05-18)
        # Only save per-player prefs when a player is selected ($client defined).
        # Checkbox unchecked = absent from params = 0 (T-05-18: coerce to 0/1).
        if ($client) {
            my $enableConnect = $paramRef->{'pref_enableSpotifyConnect'} ? 1 : 0;
            $prefs->client($client)->set('enableSpotifyConnect', $enableConnect);

            require Plugins::SpotOn::Connect::DaemonManager;
            Plugins::SpotOn::Connect::DaemonManager->initHelpers();

            # OGG-passthrough override (D-05, T-05-19): 'auto' | 'ogg' | 'pcm'
            # Whitelist validation — default to 'auto' on invalid or absent input.
            if (defined $paramRef->{'pref_connectOggOverride'}) {
                my $override = $paramRef->{'pref_connectOggOverride'};
                $override = 'auto' unless $override =~ /^(?:auto|ogg|pcm)$/;
                $prefs->client($client)->set('connectOggOverride', $override);
            }
        }
    }

    # Auto-setup: if __DISCOVER__/credentials.json exists, create account now.
    # This bridges discovery completion → account creation. The AJAX poll reloads
    # the page when credentials arrive, and this block picks them up.
    my $serverPrefs = preferences('server');
    my $discoverCredsFile = catfile(
        $serverPrefs->get('cachedir'), 'spoton', '__DISCOVER__', 'credentials.json');

    if (-f $discoverCredsFile) {
        require Plugins::SpotOn::API::TokenManager;
        _autoSetupAccount($discoverCredsFile, $serverPrefs);
    }

    # Pass account and discovery data to template for all requests
    $paramRef->{accounts}         = $prefs->get('accounts') || {};
    $paramRef->{activeAccount}    = $prefs->get('activeAccount') || '';
    $paramRef->{discoveryRunning} = _isDiscoveryRunning() ? 1 : 0;

    # Client-ID und Degraded-Mode-Status fuer Template (D-02, D-03)
    $paramRef->{customClientId} = $prefs->get('clientId') || '';
    $paramRef->{degradedMode}   = _isDegradedMode();

    # Per-player Connect settings for template (D-10, D-05)
    # Only populated when a player is selected; template guards with [% IF playerid %].
    if ($client) {
        $paramRef->{connectEnabled}     = $prefs->client($client)->get('enableSpotifyConnect') // 1;
        $paramRef->{connectOggOverride} = $prefs->client($client)->get('connectOggOverride') || 'auto';
    }

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

# ============================================================
# Auto-setup: synchronous account creation from __DISCOVER__/credentials.json.
# Reads credentials, derives accountId, renames dir, stores prefs immediately.
# Display name is fetched asynchronously afterwards (may update on next page load).
# ============================================================
sub _autoSetupAccount {
    my ($credsFile, $serverPrefs) = @_;

    open(my $fh, '<', $credsFile) or do {
        $log->error("Settings: cannot read $credsFile: $!");
        return;
    };
    local $/;
    my $json = <$fh>;
    close $fh;

    my $creds = eval { from_json($json) };
    if ($@ || !$creds->{username}) {
        $log->error("Settings: credentials.json parse failed: $@");
        return;
    }

    my $username  = $creds->{username};
    my $accountId = substr(md5_hex($username), 0, 8);
    my $baseDir   = catdir($serverPrefs->get('cachedir'), 'spoton');
    my $discoverDir = catdir($baseDir, '__DISCOVER__');
    my $finalDir    = catdir($baseDir, $accountId);

    if (-d $finalDir) {
        require File::Path;
        File::Path::remove_tree($finalDir);
    }
    require File::Copy;
    File::Copy::move($discoverDir, $finalDir) or do {
        $log->error("Settings: dir rename __DISCOVER__ -> $accountId failed: $!");
        return;
    };
    chmod(0700, $finalDir);

    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} = {
        displayName   => $username,
        spotifyUserId => $username,
    };
    $prefs->set('accounts', $accounts);

    unless ($prefs->get('activeAccount')) {
        $prefs->set('activeAccount', $accountId);
    }

    $log->info("Settings: account $accountId created from ZeroConf discovery (user=$username)");

    # Fire async /me fetch to get the real display name
    Plugins::SpotOn::API::TokenManager->_fetchDisplayName(
        $accountId, $username, sub { });
}

# ============================================================
# AJAX endpoint: /plugins/SpotOn/settings/discoveryStatus
# Returns JSON with status: 'connected' | 'waiting' | 'idle'
# Source pattern: Spotty/Settings/Auth.pm::checkCredentials (addRawFunction pattern)
# ============================================================
sub _discoveryStatusHandler {
    my ($httpClient, $response) = @_;

    my $serverPrefs = preferences('server');
    my $discoverDir = catdir($serverPrefs->get('cachedir'), 'spoton', '__DISCOVER__');
    my $credsFile   = catfile($discoverDir, 'credentials.json');

    my $result;
    if (-f $credsFile) {
        $result = { status => 'connected' };
    } elsif (_isDiscoveryRunning()) {
        $result = { status => 'waiting' };
    } else {
        $result = { status => 'idle' };
    }

    my $content = to_json($result);
    $response->header('Content-Length' => length($content));
    $response->code(200);
    $response->header('Connection' => 'close');
    $response->content_type('application/json');
    # Source: Spotty/Settings/Auth.pm line 88
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$content);
}

# ============================================================
# Helper: Degraded Mode pruefen (D-03)
# Degraded = kein Custom-Client-ID konfiguriert.
# Zeigt Hinweis in Settings damit User eigene Spotify Developer App eintragen kann.
# Analog zu _isDiscoveryRunning unten.
# ============================================================
sub _isDegradedMode {
    my $customId = $prefs->get('clientId') || '';
    return $customId ? 0 : 1;
}

# ============================================================
# Helper: check if ZeroConf discovery process is alive
# Delegates to TokenManager which owns the $discoveryProc package var
# ============================================================
sub _isDiscoveryRunning {
    # Lazy-load TokenManager to avoid circular dependency issues at startup
    # If TokenManager is not loaded yet, discovery is not running
    return 0 unless $INC{'Plugins/SpotOn/API/TokenManager.pm'};
    return Plugins::SpotOn::API::TokenManager->isDiscoveryRunning();
}

1;

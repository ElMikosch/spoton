package Plugins::SpotOn::Status;

use strict;
use warnings;

use Encode qw(encode);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

# Ring-buffer for recent errors (newest at end; returned in reverse order)
my @_errorHistory;
use constant MAX_ERROR_HISTORY => 30;

# System info cache (D-03): loaded once per LMS session
my $_systemInfo;

# ============================================================
# Constructor
# ============================================================

sub new {
    my $class = shift;

    require Slim::Web::Pages;

    # Register status.html as a page function so LMS serves and TT-processes it
    Slim::Web::Pages->addPageFunction(
        'plugins/SpotOn/status.html',
        \&_statusPageHandler
    );

    # Register JSON data endpoint
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/status/data',
        \&_statusDataHandler
    );

    return bless {}, $class;
}

# ============================================================
# Public class method: recordError
# ============================================================

sub recordError {
    my ($class, $level, $module, $message) = @_;

    push @_errorHistory, {
        ts      => time(),
        level   => $level,
        module  => $module,
        message => $message,
    };

    # Trim oldest entries beyond MAX_ERROR_HISTORY
    shift @_errorHistory while scalar @_errorHistory > MAX_ERROR_HISTORY;
}

# ============================================================
# Handler: /plugins/SpotOn/status.html (TT page)
# ============================================================

sub _statusPageHandler {
    my ($client, $params) = @_;
    return Slim::Web::HTTP::filltemplatefile('plugins/SpotOn/status.html', $params);
}

# ============================================================
# Handler: /plugins/SpotOn/status/data
# ============================================================

sub _statusDataHandler {
    my ($httpClient, $response) = @_;

    # No CSRF check — read-only endpoint (D-12)

    my %data;

    # Each collector is eval-guarded so a broken module or missing method
    # at startup returns partial data rather than crashing the handler (CR-01).

    # --- Daemons ---
    $data{daemons} = eval { _collectDaemons() } // [];
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _collectDaemons failed: $@");
    }

    # --- API telemetry ---
    require Plugins::SpotOn::API::Client;
    $data{api} = eval { Plugins::SpotOn::API::Client->statusSnapshot() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: statusSnapshot failed: $@");
    }

    # --- Errors (newest first) ---
    $data{errors} = eval { _errorHistory() } // [];

    # --- Tokens ---
    $data{tokens} = eval { _collectTokens() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _collectTokens failed: $@");
    }

    # --- System info (D-05: cached, computed once) ---
    $data{system} = eval { _systemInfo() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _systemInfo failed: $@");
    }

    _jsonResponse($httpClient, $response, \%data);
}

# ============================================================
# Data collectors
# ============================================================

sub _collectDaemons {
    my @daemons;

    require Plugins::SpotOn::Unified::DaemonManager;
    require Slim::Player::Client;
    for my $helper (Plugins::SpotOn::Unified::DaemonManager->helperInstances()) {
        my $mac  = $helper->mac;
        my $name = $mac;

        my $client = Slim::Player::Client::getClient($mac);
        $name = $client->name if $client && $client->can('name');

        my $playing      = 0;
        my $currentTrack = undef;
        my $syncGroup    = undef;

        if ($client) {
            # Playback status: only report when playing a SpotOn track
            if ($client->isPlaying) {
                my $url = Slim::Player::Playlist::url($client) || '';
                if ($url =~ /^spoton:/) {
                    $playing = 1;
                    require Plugins::SpotOn::ProtocolHandler;
                    my $meta = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, $url);
                    $currentTrack = $meta->{title} if $meta && $meta->{title};
                }
            }

            # Sync group members
            if ($client->isSynced()) {
                my @members;
                for my $peer ($client->syncGroupActiveMembers()) {
                    push @members, $peer->name if $peer->id ne $mac;
                }
                $syncGroup = \@members if @members;
            }
        }

        push @daemons, {
            mac            => $mac,
            name           => $name,
            alive          => $helper->alive ? 1 : 0,
            pid            => $helper->pid || 0,
            uptime         => int($helper->uptime || 0),
            connectEnabled => $helper->_connectEnabled ? 1 : 0,
            streamPort     => $helper->_streamPort // undef,
            playing        => $playing,
            currentTrack   => $currentTrack,
            syncGroup      => $syncGroup,
            sessionHealth  => $helper->_lastHealthSession,
        };
    }

    return \@daemons;
}

sub _collectTokens {
    require Plugins::SpotOn::API::TokenManager;
    return {
        accountCount     => scalar(Plugins::SpotOn::API::TokenManager->getAccountIds()),
        discoveryRunning => Plugins::SpotOn::API::TokenManager->isDiscoveryRunning() ? 1 : 0,
    };
}

sub _errorHistory {
    return [ reverse @_errorHistory ];
}

sub _systemInfo {
    return $_systemInfo if $_systemInfo;

    require Plugins::SpotOn::Helper;
    require Plugins::SpotOn::Plugin;
    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    $_systemInfo = {
        pluginVersion => Plugins::SpotOn::Plugin->_pluginDataFor('version') || 'unknown',
        binaryVersion => $helperVersion || 'unknown',
        lmsVersion    => $::VERSION,
        perlVersion   => $],
        os            => $^O,
    };

    return $_systemInfo;
}

# ============================================================
# JSON response helper (verbatim from Settings.pm lines 466-475)
# ============================================================

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

1;

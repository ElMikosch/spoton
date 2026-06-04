package Plugins::SpotOn::Connect::DaemonManager;

use strict;

use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SpotOn::Plugin;
use Plugins::SpotOn::Connect::Daemon;

# Buffer the helper initialization to prevent a flurry of activity when
# players connect/disconnect.
use constant DAEMON_INIT_DELAY        => 2;
use constant DAEMON_WATCHDOG_INTERVAL => 60;

# Fast poll interval for streaming daemons — keeps crash-silence window <=5s
use constant STREAM_WATCHDOG_INTERVAL => 5;

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

my %helperInstances;

sub _isConnectEnabled {
    my $client = shift;
    return $prefs->client($client)->get('enableSpotifyConnect')
        // $prefs->get('enableSpotifyConnect');
}

sub init {
    my $class = shift;

    # Debounced init on client connect/disconnect (2s delay to batch events)
    Slim::Control::Request::subscribe(sub {
        Slim::Utils::Timers::killTimers($class, \&initHelpers);
        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers);
    }, [['client'], ['new', 'disconnect']]);

    # CON-15: Differential restart on sync changes.
    # Stop each daemon via stopForSync (clears stream port, resets backoff) then
    # re-init with a 0.1s micro-delay instead of DAEMON_INIT_DELAY (2s), so
    # Spirc re-registration happens fast enough for the Spotify app to see the
    # refreshed device within ~10s.
    Slim::Control::Request::subscribe(sub {
        my $request = shift;

        return if $request->isNotCommand([['sync']]);

        my $client = $request->client();
        my @affected;
        if ($client) {
            push @affected, $client->id;
            if ($client->isSynced() && $client->master) {
                push @affected, $client->master->id;
                push @affected, map { $_->id } Slim::Player::Sync::slaves($client->master);
            }
        }

        main::INFOLOG && $log->is_info && $log->info(
            "Sync group changed - restarting affected daemons: " . join(', ', @affected)
        );

        Slim::Utils::Timers::killTimers($class, \&initHelpers);

        for my $clientId (@affected) {
            $helperInstances{$clientId}->stopForSync() if $helperInstances{$clientId};
        }

        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 0.1, \&initHelpers);
    }, [['sync']]);

    # Per-player Connect toggle reaction is handled by Settings.pm calling
    # initHelpers() directly after saving — setChange on global prefs namespace
    # doesn't fire for per-player prefs (WR-01 fix).

    # Immediate initial check — player may already be connected before listeners registered
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 0.5, \&initHelpers);
}

sub initHelpers {
    my $class = __PACKAGE__;

    Slim::Utils::Timers::killTimers($class, \&initHelpers);

    # D-01: Reset crash-loop flags BEFORE evaluating daemons. Done here (not in
    # init()) because players may not be connected yet when init() runs at startup.
    for my $client (Slim::Player::Client::clients()) {
        if ($prefs->client($client)->get('discoveryDisabledByCrashLoop')) {
            main::INFOLOG && $log->is_info && $log->info(
                "Resetting discoveryDisabledByCrashLoop for " . $client->id
            );
            $prefs->client($client)->set('discoveryDisabledByCrashLoop', 0);
        }
    }
    if ($prefs->get('disableDiscovery')) {
        main::INFOLOG && $log->is_info && $log->info(
            "Resetting global disableDiscovery flag (crash-loop fallback)"
        );
        $prefs->set('disableDiscovery', 0);
    }

    main::INFOLOG && $log->is_info && $log->info("Checking SpotOn Connect helper daemons...");

    # Shut down orphaned instances (players that disconnected)
    $class->shutdown('inactive-only');

    # Deduplicate by MAC: LMS may return multiple client objects for the same
    # MAC address (e.g. UPnP bridge + squeezelite sharing a MAC). Process
    # synced clients first so that sync group membership is detected before
    # standalone duplicates are evaluated.
    my @clients = sort {
        ($b->isSynced() ? 1 : 0) <=> ($a->isSynced() ? 1 : 0)
    } Slim::Player::Client::clients();

    # %handled: MAC => 'started' | 'seen'
    # 'started' = daemon started for this MAC; 'seen' = processed, no daemon needed
    my %handled;

    for my $client (@clients) {
        next if $handled{$client->id};

        my $syncMaster;

        if (Slim::Player::Sync::isSlave($client) && (my $master = $client->master)) {
            if (_isConnectEnabled($master)) {
                $syncMaster = $master->id;
            }
            else {
                ($syncMaster) = map { $_->id } grep {
                    _isConnectEnabled($_)
                } sort { $a->id cmp $b->id } Slim::Player::Sync::slaves($master);
            }
        }

        if ($syncMaster && $syncMaster eq $client->id) {
            main::INFOLOG && $log->is_info && $log->info(
                "Sync group Connect delegate (elected slave): $syncMaster"
            );
            $class->startHelper($client);
            $handled{$client->id} = 'started';
        }
        elsif ($syncMaster) {
            main::INFOLOG && $log->is_info && $log->info(
                "Sync group slave, daemon runs on $syncMaster: " . $client->id
            );
            $class->stopHelper($client);
            $handled{$client->id} = 'seen';

            if (!$handled{$syncMaster}) {
                my $delegateClient = Slim::Player::Client::getClient($syncMaster);
                if ($delegateClient && _isConnectEnabled($delegateClient)) {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Starting daemon for sync group delegate: $syncMaster"
                    );
                    $class->startHelper($delegateClient);
                    $handled{$syncMaster} = 'started';
                }
            }
        }
        elsif (!$syncMaster && _isConnectEnabled($client)) {
            if (!$handled{$client->id}) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Standalone player with Spotify Connect enabled: " . $client->id
                );
                $class->startHelper($client);
                $handled{$client->id} = 'started';
            }
        }
        else {
            main::INFOLOG && $log->is_info && $log->info(
                "Standalone player with Spotify Connect disabled: " . $client->id
            );
            $class->stopHelper($client);
            $handled{$client->id} = 'seen';
        }
    }

    # 60s watchdog: ensure daemons are alive even without player events
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers);
}

sub _streamAlivePoll {
    my $class = __PACKAGE__;

    Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);

    my @streaming = grep { $_->_streamMode } values %helperInstances;

    # Self-stop when no streaming daemons are active — avoids idle timer overhead
    return unless @streaming;

    for my $helper (@streaming) {
        if (!$helper->alive) {
            main::INFOLOG && $log->is_info && $log->info(
                "SpotOn stream daemon crashed for " . $helper->mac . " - restarting immediately"
            );
            $helper->start;
        }
        elsif (main::DEBUGLOG && $log->is_debug) {
            $log->debug("SpotOn stream daemon alive: " . $helper->mac . " pid=" . ($helper->pid || '?'));
        }
    }

    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + STREAM_WATCHDOG_INTERVAL,
        \&_streamAlivePoll
    );
}

sub startHelper {
    my ($class, $clientId) = @_;

    $clientId = $clientId->id if $clientId && blessed $clientId;

    # No need to restart if already present and alive
    my $helper = $helperInstances{$clientId};

    if (!$helper) {
        main::INFOLOG && $log->is_info && $log->info("Need to create Connect daemon for $clientId");
        $helper = $helperInstances{$clientId} = Plugins::SpotOn::Connect::Daemon->new($clientId);
    }
    elsif (!$helper->alive) {
        main::INFOLOG && $log->is_info && $log->info("Need to (re-)start Connect daemon for $clientId");
        $helper->start;
    }

    # NOTE: checkDaemonConnected block deliberately NOT present (was 429 source; CON-09)

    # Activate fast stream poll when a streaming daemon comes online
    if ($helper && $helper->_streamMode) {
        Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);
        Slim::Utils::Timers::setTimer(
            $class,
            Time::HiRes::time() + STREAM_WATCHDOG_INTERVAL,
            \&_streamAlivePoll
        );
    }

    return $helper if $helper && $helper->alive;
}

sub stopHelper {
    my ($class, $clientId) = @_;

    $clientId = $clientId->id if $clientId && blessed $clientId;

    my $helper = delete $helperInstances{$clientId};

    if ($helper && $helper->alive) {
        main::INFOLOG && $log->is_info && $log->info(
            sprintf("Shutting down Connect daemon for $clientId (pid: %s)", $helper->pid)
        );
        $helper->stop;
    }

    # Stop the fast stream poll when the last streaming daemon is removed
    unless (grep { $_->_streamMode } values %helperInstances) {
        Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);
    }
}

sub shutdown {
    my ($class, $mode) = @_;

    # 'inactive-only': only stop helpers for players no longer connected
    my %activeClientIds;
    if ($mode && $mode eq 'inactive-only') {
        %activeClientIds = map { $_->id => 1 } Slim::Player::Client::clients();
    }

    foreach my $clientId (keys %helperInstances) {
        # In inactive-only mode, skip helpers for still-connected players
        next if %activeClientIds && $activeClientIds{$clientId};
        $class->stopHelper($clientId);
    }

    unless ($mode && $mode eq 'inactive-only') {
        Slim::Utils::Timers::killTimers($class, \&initHelpers);
        Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);
    }
}

# helperForClient($class, $clientId)
# Returns the Daemon instance for a given player (by id or client object).
# For synced players, also checks the sync group master and slaves if no
# daemon is found directly — handles the case where the daemon is registered
# under the sync master's MAC but the lookup uses a slave's MAC.
sub helperForClient {
    my ($class, $clientId) = @_;

    my $client;
    if ($clientId && blessed $clientId) {
        $client = $clientId;
        $clientId = $clientId->id;
    }

    return unless $clientId;

    # Direct lookup — fastest path
    my $helper = $helperInstances{$clientId};
    return $helper if $helper && $helper->alive;

    # Sync group fallback: if the direct MAC has no daemon, check the sync
    # master and all sync members. This covers the case where the daemon
    # runs under the master's MAC but the lookup comes via a slave MAC.
    if (!$client) {
        $client = Slim::Player::Client::getClient($clientId);
    }
    if ($client && $client->isSynced()) {
        my $master = $client->master;
        if ($master) {
            $helper = $helperInstances{$master->id};
            return $helper if $helper && $helper->alive;

            for my $slave (Slim::Player::Sync::slaves($master)) {
                $helper = $helperInstances{$slave->id};
                return $helper if $helper && $helper->alive;
            }
        }
    }

    return undef;
}

# streamPortForClient($class, $clientId)
# Returns the HTTP stream port for the Connect daemon serving this player.
sub streamPortForClient {
    my ($class, $clientId) = @_;
    $clientId = $clientId->id if $clientId && blessed $clientId;
    my $helper = $class->helperForClient($clientId) || return;
    return $helper->_streamPort;
}

# helperPids($class)
# Returns list of PIDs for all currently-alive Connect daemons.
# Called by Plugin.pm::_killOrphanedProcesses to exclude Connect daemon PIDs
# from orphan cleanup (CON-09 / Pitfall 6).
sub helperPids {
    my $class = shift;
    return map { $_->pid } grep { $_->alive } values %helperInstances;
}

# uptime($class, $clientId)
# Returns seconds since last daemon start for the given player, or 0 if not found.
sub uptime {
    my ($class, $clientId) = @_;
    return 0 unless $clientId;
    my $helper = $class->helperForClient($clientId) || return 0;
    return $helper->uptime();
}

# helperInstances($class)
# Returns all Daemon instances (for inspection/iteration by Connect.pm).
sub helperInstances {
    my $class = shift;
    return values %helperInstances;
}

1;

package Plugins::SpotOn::Browse::DaemonManager;

use strict;

use File::Basename qw(basename);
use File::Spec::Functions qw(catdir catfile);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SpotOn::Plugin;
use Plugins::SpotOn::Browse::Daemon;

# Buffer the helper initialization to prevent a flurry of activity when
# players connect/disconnect.
use constant DAEMON_INIT_DELAY        => 2;
use constant DAEMON_WATCHDOG_INTERVAL => 60;

# Fast poll interval for Browse daemons — keeps crash-silence window <=5s
use constant STREAM_WATCHDOG_INTERVAL => 5;

# Delay before cleaning up orphaned log files (seconds after init)
# Gives players time to reconnect after LMS restart before their logs are deleted.
use constant ORPHAN_LOG_CLEANUP_DELAY => 30;

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

my %helperInstances;

sub init {
    my $class = shift;

    # Debounced init on client connect/disconnect (2s delay to batch events)
    Slim::Control::Request::subscribe(sub {
        Slim::Utils::Timers::killTimers($class, \&initHelpers);
        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers);
    }, [['client'], ['new', 'disconnect']]);

    # Sync change handler: stop affected Browse daemons then fast-restart (0.1s micro-delay).
    # Browse daemon has no discovery state to preserve — plain stop() is sufficient.
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
            "Sync group changed - restarting affected Browse daemons: " . join(', ', @affected)
        );

        Slim::Utils::Timers::killTimers($class, \&initHelpers);

        for my $clientId (@affected) {
            $helperInstances{$clientId}->stop() if $helperInstances{$clientId};
        }

        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 0.1, \&initHelpers);
    }, [['sync']]);

    # Immediate initial check — player may already be connected before listeners registered
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 0.5, \&initHelpers);

    # Delayed cleanup of orphaned browse log files from players no longer connected.
    # 30s delay ensures players have had time to reconnect after LMS restart.
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + ORPHAN_LOG_CLEANUP_DELAY, \&_cleanupOrphanedLogs);
}

sub initHelpers {
    my $class = __PACKAGE__;

    Slim::Utils::Timers::killTimers($class, \&initHelpers);

    main::INFOLOG && $log->is_info && $log->info("Checking SpotOn Browse helper daemons...");

    # Shut down orphaned instances (players that disconnected)
    $class->shutdown('inactive-only');

    # Check browseMode — Browse daemon only starts when browseMode=http
    my $browseMode = $prefs->get('browseMode') // 'http';
    unless ($browseMode eq 'http') {
        main::INFOLOG && $log->is_info && $log->info(
            "Browse daemon disabled (browseMode=$browseMode) — stopping all"
        );
        $class->shutdown();
        return;
    }

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

        # Browse daemon starts for ALL connected players when browseMode=http —
        # no _isConnectEnabled gate. Sync groups still share one daemon (on master).
        if (Slim::Player::Sync::isSlave($client) && (my $master = $client->master)) {
            # Slave: daemon runs on the sync master
            my $syncMasterId = $master->id;

            main::INFOLOG && $log->is_info && $log->info(
                "Sync group slave, Browse daemon runs on $syncMasterId: " . $client->id
            );
            $class->stopHelper($client);
            $handled{$client->id} = 'seen';

            if (!$handled{$syncMasterId}) {
                my $delegateClient = Slim::Player::Client::getClient($syncMasterId);
                if ($delegateClient) {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Starting Browse daemon for sync group master: $syncMasterId"
                    );
                    $class->startHelper($delegateClient);
                    $handled{$syncMasterId} = 'started';
                }
            }
        }
        else {
            # Standalone player or sync master — start directly
            main::INFOLOG && $log->is_info && $log->info(
                "Starting Browse daemon for player: " . $client->id
            );
            $class->startHelper($client);
            $handled{$client->id} = 'started';
        }
    }

    # 60s watchdog: ensure daemons are alive even without player events
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers);
}

sub _streamAlivePoll {
    my $class = __PACKAGE__;

    Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);

    # Browse daemon is always a streaming daemon when alive — no _streamMode gate
    my @alive = grep { $_->alive } values %helperInstances;

    # Self-stop when no Browse daemons are active — avoids idle timer overhead
    return unless @alive;

    for my $helper (@alive) {
        if (!$helper->alive) {
            main::INFOLOG && $log->is_info && $log->info(
                "SpotOn Browse daemon crashed for " . $helper->mac . " - restarting immediately"
            );
            $helper->start;
        }
        elsif (main::DEBUGLOG && $log->is_debug) {
            $log->debug("SpotOn Browse daemon alive: " . $helper->mac . " pid=" . ($helper->pid || '?'));
        }
    }

    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + STREAM_WATCHDOG_INTERVAL,
        \&_streamAlivePoll
    );
}

sub _cleanupOrphanedLogs {
    my $baseDir = catdir($serverPrefs->get('cachedir'), 'spoton');

    return unless -d $baseDir;

    my @logFiles = glob(catfile($baseDir, '*-browse.log'));
    return unless @logFiles;

    for my $f (@logFiles) {
        next unless basename($f) =~ /^([0-9a-f]{12})-browse\.log$/i;
        my $macClean = $1;
        my $mac = join(':', $macClean =~ /../g);

        my $client = Slim::Player::Client::getClient($mac);
        if (!$client || !$client->connected) {
            my $mtime = (stat($f))[9] || 0;
            if (time() - $mtime > 300) {
                unlink $f;
                $log->warn("Cleaned up orphaned Browse log: " . basename($f));
            }
        }
    }
}

sub startHelper {
    my ($class, $clientId) = @_;

    $clientId = $clientId->id if $clientId && blessed $clientId;

    # Credential pre-check: skip daemon start if no cached credentials exist.
    # Mirrors Daemon.pm start() cache dir construction (CON-01 account-level scope).
    # Without this, librespot starts, finds no credentials, and exits immediately —
    # triggering crash-loop detection, filling logs with noise.
    my $activeAccountId = $prefs->get('activeAccount') || '';
    my $cacheDir = $activeAccountId
        ? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
        : catdir($serverPrefs->get('cachedir'), 'spoton');
    my $credFile = catfile($cacheDir, 'credentials.json');

    if (! -f $credFile) {
        main::INFOLOG && $log->is_info && $log->info(
            "Skipping Browse daemon for $clientId - no cached credentials (expected: $credFile)"
        );
        return;
    }

    # No need to restart if already present and alive
    my $helper = $helperInstances{$clientId};

    if (!$helper) {
        main::INFOLOG && $log->is_info && $log->info("Need to create Browse daemon for $clientId");
        $helper = $helperInstances{$clientId} = Plugins::SpotOn::Browse::Daemon->new($clientId);
    }
    elsif (!$helper->alive) {
        main::INFOLOG && $log->is_info && $log->info("Need to (re-)start Browse daemon for $clientId");
        $helper->start;
    }

    # Browse daemon is always streaming when alive — activate fast poll unconditionally
    Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + STREAM_WATCHDOG_INTERVAL,
        \&_streamAlivePoll
    );

    return $helper if $helper && $helper->alive;
}

sub stopHelper {
    my ($class, $clientId) = @_;

    $clientId = $clientId->id if $clientId && blessed $clientId;

    my $helper = delete $helperInstances{$clientId};

    if ($helper && $helper->alive) {
        main::INFOLOG && $log->is_info && $log->info(
            sprintf("Shutting down Browse daemon for $clientId (pid: %s)", $helper->pid)
        );
        $helper->stop;
    }

    # Stop the fast poll when the last Browse daemon is removed
    unless (grep { $_->alive } values %helperInstances) {
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
        $client   = $clientId;
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

# helperPids($class)
# Returns list of PIDs for all currently-alive Browse daemons.
# Called by Plugin.pm::_killOrphanedProcesses to exclude Browse daemon PIDs
# from orphan cleanup (CON-09 / Pitfall 6).
sub helperPids {
    my $class = shift;
    return map { $_->pid } grep { $_->alive } values %helperInstances;
}

1;

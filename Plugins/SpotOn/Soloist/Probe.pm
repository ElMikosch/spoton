package Plugins::SpotOn::Soloist::Probe;

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec::Functions qw(catdir);
use Time::HiRes ();

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SpotOn::Soloist::Session;
use Plugins::SpotOn::Soloist::Transport;
use Plugins::SpotOn::Soloist::AudioPreflight;

use constant RETRY_INTERVAL     => 0.5;
use constant MAX_RETRY_ATTEMPTS => 20;

my $log         = Slim::Utils::Log->logger('plugin.spoton');
my $prefs       = Slim::Utils::Prefs::preferences('plugin.spoton');
my $serverPrefs = Slim::Utils::Prefs::preferences('server');

my $session;
my $running       = 0;
my $retryAttempts = 0;
my $lastUpdate;
my $lastEventType;

my %CONTROL_ACTIONS = map { $_ => 1 } qw(
    activate
    add_to_queue
    auth_state
    deactivate
    next
    pause
    play
    previous
    queue
    repeat
    seek
    shuffle
    state
    volume
);

sub init {
    Slim::Control::Request::addDispatch(
        ['spoton', 'soloistprobe'],
        [0, 1, 1, \&_cli_handler],
    );
    return 1;
}

sub shutdown {
    $running = 0;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_retry);
    $session->stop() if $session;
    undef $session;
    $retryAttempts = 0;
    if ($INC{'Plugins/SpotOn/Soloist/Manager.pm'}) {
        Plugins::SpotOn::Soloist::Manager->shutdown();
    }
    return 1;
}

sub dataDir {
    return catdir($serverPrefs->get('cachedir'), 'spoton', 'soloist-probe');
}

sub start {
    my $class = shift;

    my $data_dir = dataDir();
    eval { make_path($data_dir) unless -d $data_dir; };
    if ($@ || !-d $data_dir) {
        $log->warn("Soloist probe: unable to create data directory: $@");
        return 0;
    }

    $running = 1;
    $retryAttempts = 0;

    $session ||= Plugins::SpotOn::Soloist::Session->new(
        data_dir => $data_dir,
        on_update => sub {
            my ($event) = @_;
            $lastUpdate = time();
            $lastEventType = $event->{event_type};
        },
        on_status => sub {
            my ($status) = @_;
            if ($status eq 'connected') {
                $retryAttempts = 0;
                main::INFOLOG && $log->is_info
                    && $log->info('Soloist probe connected to local WebSocket');
            }
            elsif ($running && ($status eq 'waiting_endpoint' || $status eq 'disconnected')) {
                _schedule_retry();
            }
        },
        on_error => sub {
            my ($code, $message) = @_;
            $log->warn("Soloist probe $code: $message")
                if $prefs->get('diagnosticMode');
        },
    );

    my $started = $session->start();
    _schedule_retry() if !$started && $session->status eq 'waiting_endpoint';
    return $started ? 1 : 0;
}

sub stop {
    $running = 0;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_retry);
    $session->stop() if $session;
    return 1;
}

sub sendAction {
    my ($class, $action, %args) = @_;
    return 0 unless $CONTROL_ACTIONS{$action};
    return 0 unless $session && $session->connected;
    return $session->send_action($action, %args);
}

sub statusSnapshot {
    my $session_snapshot = $session ? $session->snapshot() : undef;
    my $websocket_available =
        Plugins::SpotOn::Soloist::Transport->websocket_available();

    return {
        enabled             => $running ? 1 : 0,
        websocketAvailable  => $websocket_available,
        dataDir             => dataDir(),
        status              => $session ? $session->status() : 'idle',
        endpoint            => $session ? $session->endpoint() : undef,
        state               => $session_snapshot,
        retryAttempts       => $retryAttempts,
        lastUpdate          => $lastUpdate,
        lastEventType       => $lastEventType,
        preflight           => Plugins::SpotOn::Soloist::AudioPreflight->inspect(
            websocket_available => $websocket_available,
        ),
    };
}

sub _schedule_retry {
    return unless $running;
    return if $retryAttempts >= MAX_RETRY_ATTEMPTS;

    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_retry);
    Slim::Utils::Timers::setTimer(
        __PACKAGE__,
        Time::HiRes::time() + RETRY_INTERVAL,
        \&_retry,
    );
}

sub _retry {
    return unless $running && $session;
    return if $session->connected;

    $retryAttempts++;
    my $started = $session->refresh();
    _schedule_retry() unless $started || $retryAttempts >= MAX_RETRY_ATTEMPTS;
}

sub _cli_handler {
    my $request = shift;

    if ($request->isNotQuery([['spoton'], ['soloistprobe']])) {
        $request->setStatusBadDispatch();
        return;
    }

    # This surface is intentionally diagnostics-only. It never starts or stops
    # the Soloist daemon itself and never accepts an arbitrary filesystem path.
    unless ($prefs->get('diagnosticMode')) {
        $request->addResult('error', 'diagnostic_mode_required');
        $request->setStatusBadParams();
        return;
    }

    my $action = $request->getParam('action') || 'status';

    if ($action eq 'start') {
        __PACKAGE__->start();
    }
    elsif ($action eq 'stop') {
        __PACKAGE__->stop();
    }
    elsif ($action eq 'managed_start') {
        require Plugins::SpotOn::Soloist::Manager;
        Plugins::SpotOn::Soloist::Manager->init();
        Plugins::SpotOn::Soloist::Manager->start();
    }
    elsif ($action eq 'managed_stop') {
        require Plugins::SpotOn::Soloist::Manager;
        Plugins::SpotOn::Soloist::Manager->stop();
    }
    elsif ($action eq 'managed_status') {
        require Plugins::SpotOn::Soloist::Manager;
    }
    elsif ($action ne 'status') {
        unless ($CONTROL_ACTIONS{$action}) {
            $request->addResult('error', 'unsupported_action');
            $request->setStatusBadParams();
            return;
        }

        my %args = _command_args($request, $action);
        unless (__PACKAGE__->sendAction($action, %args)) {
            $request->addResult('error', 'command_failed');
            $request->setStatusBadParams();
            return;
        }
    }

    $request->addResult('soloist', statusSnapshot());
    if ($INC{'Plugins/SpotOn/Soloist/Manager.pm'}) {
        $request->addResult(
            'managed',
            Plugins::SpotOn::Soloist::Manager->statusSnapshot(),
        );
    }
    $request->setStatusDone();
}

sub _command_args {
    my ($request, $action) = @_;

    return (uri => $request->getParam('uri'))
        if ($action eq 'play' || $action eq 'add_to_queue')
            && defined $request->getParam('uri');
    return (position_ms => $request->getParam('position_ms')) if $action eq 'seek';
    return (volume => $request->getParam('volume')) if $action eq 'volume';
    return (enabled => $request->getParam('enabled')) if $action eq 'shuffle';
    return (mode => $request->getParam('mode')) if $action eq 'repeat';
    return (limit => $request->getParam('limit'))
        if $action eq 'queue' && defined $request->getParam('limit');
    return ();
}

1;

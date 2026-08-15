#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

BEGIN {
    package main;
    sub INFOLOG () { 0 }

    package Slim::Utils::Log;
    sub import { }
    sub logger { return bless {}, 'Local::Log' }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package Local::Log;
    sub is_info { 0 }
    sub info    { }
    sub warn    { push @Local::Log::warnings, $_[1] }

    package Slim::Utils::Prefs;
    our %values;
    sub import { }
    sub preferences { return bless { namespace => $_[0] }, 'Local::Prefs' }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package Local::Prefs;
    sub get { return $Slim::Utils::Prefs::values{ $_[0]{namespace} }{ $_[1] } }
    sub set { $Slim::Utils::Prefs::values{ $_[0]{namespace} }{ $_[1] } = $_[2] }

    package Slim::Utils::Timers;
    our @set;
    our @killed;
    sub setTimer   { push @set, [@_] }
    sub killTimers { push @killed, [@_] }
    $INC{'Slim/Utils/Timers.pm'} = 1;

    package Slim::Control::Request;
    our @dispatches;
    sub addDispatch { push @dispatches, [@_] }
    $INC{'Slim/Control/Request.pm'} = 1;
}

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Probe;

{
    package Local::FakeSession;

    our $mode = 'connected';
    our @instances;

    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            callbacks => { %args },
            status    => 'idle',
            connected => 0,
            actions   => [],
            stopped   => 0,
        }, 'Local::FakeSession';
        push @instances, $self;
        return $self;
    }

    sub start {
        my ($self) = @_;
        if ($mode eq 'connected') {
            $self->{status} = 'connected';
            $self->{connected} = 1;
            $self->{callbacks}{on_status}->('connected', {})
                if $self->{callbacks}{on_status};
            return 1;
        }
        $self->{status} = 'waiting_endpoint';
        $self->{callbacks}{on_status}->('waiting_endpoint', {})
            if $self->{callbacks}{on_status};
        return 0;
    }

    sub refresh { shift->start() }
    sub status { $_[0]{status} }
    sub connected { $_[0]{connected} }
    sub snapshot {
        return {
            connection => $_[0]{status},
            auth       => { logged_in => 1 },
            playback   => {},
        };
    }
    sub endpoint { return { url => 'ws://127.0.0.1:19090', pid => 1234 } }
    sub send_action {
        my ($self, $action, %args) = @_;
        push @{ $self->{actions} }, [$action, { %args }];
        return 1;
    }
    sub stop {
        $_[0]{stopped} = 1;
        $_[0]{connected} = 0;
        $_[0]{status} = 'stopped';
        return 1;
    }
}

{
    package Local::Request;
    sub new { bless { params => $_[1] || {}, results => {} }, $_[0] }
    sub isNotQuery { $_[0]{not_query} || 0 }
    sub getParam { $_[0]{params}{ $_[1] } }
    sub addResult { $_[0]{results}{ $_[1] } = $_[2] }
    sub setStatusDone { $_[0]{status} = 'done' }
    sub setStatusBadParams { $_[0]{status} = 'bad_params' }
    sub setStatusBadDispatch { $_[0]{status} = 'bad_dispatch' }
}

my $cache_dir = tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::values{server}{cachedir} = $cache_dir;
$Slim::Utils::Prefs::values{'plugin.spoton'}{diagnosticMode} = 0;

ok(Plugins::SpotOn::Soloist::Probe->init(), 'probe registers CLI surface');
is(scalar @Slim::Control::Request::dispatches, 1, 'one CLI dispatch is registered');
is_deeply(
    $Slim::Control::Request::dispatches[0][0],
    ['spoton', 'soloistprobe'],
    'CLI dispatch uses isolated diagnostic command',
);

my $blocked = Local::Request->new({ action => 'start' });
Plugins::SpotOn::Soloist::Probe::_cli_handler($blocked);
is($blocked->{status}, 'bad_params', 'probe CLI is blocked outside diagnostic mode');
is($blocked->{results}{error}, 'diagnostic_mode_required', 'blocked CLI explains requirement');

$Slim::Utils::Prefs::values{'plugin.spoton'}{diagnosticMode} = 1;

{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Session::new = \&Local::FakeSession::new;
    local *Plugins::SpotOn::Soloist::Transport::websocket_available = sub { 1 };

    my $start = Local::Request->new({ action => 'start' });
    Plugins::SpotOn::Soloist::Probe::_cli_handler($start);
    is($start->{status}, 'done', 'diagnostic start command succeeds');
    is($start->{results}{soloist}{status}, 'connected', 'start returns connected state');
    ok($start->{results}{soloist}{enabled}, 'start marks probe enabled');
    ok($start->{results}{soloist}{websocketAvailable}, 'status reports LMS WebSocket support');
    like(
        $start->{results}{soloist}{dataDir},
        qr{\Q$cache_dir\E.*soloist-probe\z},
        'probe uses fixed cache-local data directory',
    );
    ok(-d $start->{results}{soloist}{dataDir}, 'start creates fixed data directory');

    my $session = $Local::FakeSession::instances[-1];
    my $volume = Local::Request->new({ action => 'volume', volume => 37 });
    Plugins::SpotOn::Soloist::Probe::_cli_handler($volume);
    is($volume->{status}, 'done', 'allowed control action succeeds');
    is_deeply(
        $session->{actions}[-1],
        ['volume', { volume => 37 }],
        'control parameter is delegated to session',
    );

    my $unsupported = Local::Request->new({ action => 'launch_shell' });
    Plugins::SpotOn::Soloist::Probe::_cli_handler($unsupported);
    is($unsupported->{status}, 'bad_params', 'unknown action is rejected');
    is($unsupported->{results}{error}, 'unsupported_action', 'unknown action has stable error');

    my $status = Local::Request->new({ action => 'status' });
    Plugins::SpotOn::Soloist::Probe::_cli_handler($status);
    is($status->{status}, 'done', 'read-only status command succeeds');
    is($status->{results}{soloist}{endpoint}{pid}, 1234, 'status contains endpoint snapshot');

    my $stop = Local::Request->new({ action => 'stop' });
    Plugins::SpotOn::Soloist::Probe::_cli_handler($stop);
    is($stop->{status}, 'done', 'stop command succeeds');
    ok($session->{stopped}, 'stop closes diagnostic session');
    ok(!$stop->{results}{soloist}{enabled}, 'stop marks probe disabled');
}

Plugins::SpotOn::Soloist::Probe->shutdown();
@Slim::Utils::Timers::set = ();
$Local::FakeSession::mode = 'waiting';

{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Session::new = \&Local::FakeSession::new;
    ok(!Plugins::SpotOn::Soloist::Probe->start(), 'probe tolerates daemon startup race');
    is(
        $Local::FakeSession::instances[-1]{status},
        'waiting_endpoint',
        'session remains in endpoint wait state',
    );
    ok(scalar @Slim::Utils::Timers::set >= 1, 'endpoint wait schedules retry timer');
}

Plugins::SpotOn::Soloist::Probe->shutdown();

done_testing();

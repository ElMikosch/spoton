#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

BEGIN {
    package main;
    sub INFOLOG () { 0 }

    package Slim::Utils::Log;
    sub import { }
    sub logger { bless {}, 'Local::Log' }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package Local::Log;
    sub warn { }
    sub info { }
    sub is_info { 0 }

    package Slim::Utils::Prefs;
    our %values;
    sub import { }
    sub preferences { bless { namespace => $_[0] }, 'Local::Prefs' }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package Local::Prefs;
    sub get { $Slim::Utils::Prefs::values{ $_[0]{namespace} }{ $_[1] } }
    sub set { $Slim::Utils::Prefs::values{ $_[0]{namespace} }{ $_[1] } = $_[2] }

    package Slim::Utils::Timers;
    our @set;
    our @killed;
    sub setTimer { push @set, [@_] }
    sub killTimers { push @killed, [@_] }
    $INC{'Slim/Utils/Timers.pm'} = 1;

    package Slim::Utils::Network;
    sub serverAddr { '192.0.2.10' }
    $INC{'Slim/Utils/Network.pm'} = 1;

    package Slim::Control::Request;
    our @requests;
    sub new {
        my ($class, $client_id, $command) = @_;
        my $self = bless {
            client_id => $client_id,
            command   => [@$command],
            executed  => 0,
        }, $class;
        push @requests, $self;
        return $self;
    }
    sub source { $_[0]{source} = $_[1] }
    sub execute { $_[0]{executed} = 1; 1 }
    $INC{'Slim/Control/Request.pm'} = 1;
}

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Manager;
use Plugins::SpotOn::Soloist::AudioPreflight;
use Plugins::SpotOn::Soloist::Transport;
use Plugins::SpotOn::Soloist::Runtime;
use Plugins::SpotOn::Soloist::Session;
use Plugins::SpotOn::Soloist::StreamServer;

{
    package Local::Runtime;
    our @instances;
    our @pipeline_formats;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            args    => { %args },
            state   => 'stopped',
            stopped => 0,
        }, 'Local::Runtime';
        push @instances, $self;
        return $self;
    }
    sub start { $_[0]{state} = 'starting_pulse'; 1 }
    sub poll {
        my ($self) = @_;
        $self->{state} = 'running' if $self->{state} eq 'starting_pulse';
        return $self->{state};
    }
    sub state { $_[0]{state} }
    sub last_error { $_[0]{last_error} }
    sub stop { $_[0]{stopped}++; $_[0]{state} = 'stopped'; 1 }
    sub status_snapshot { return { state => $_[0]{state}, soloistArgv => ['--api-key', '[REDACTED]'] } }
    sub new_stream_pipeline {
        push @pipeline_formats, defined $_[1] ? $_[1] : 'flac';
        return bless {}, 'Local::Pipeline';
    }
}

{
    package Local::Session;
    our @instances;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            args      => { %args },
            status    => 'idle',
            connected => 0,
            stopped   => 0,
        }, 'Local::Session';
        push @instances, $self;
        return $self;
    }
    sub start { $_[0]{status} = 'connected'; $_[0]{connected} = 1; 1 }
    sub refresh { $_[0]{connected} = 1; $_[0]{status} = 'connected'; 1 }
    sub connected { $_[0]{connected} }
    sub status { $_[0]{status} }
    sub snapshot { return { connection => $_[0]{status} } }
    sub stop { $_[0]{stopped}++; $_[0]{connected} = 0; $_[0]{status} = 'stopped'; 1 }
}

{
    package Local::Pipeline;
    sub start { 1 }
    sub stop { 1 }
}

{
    package Local::Player;
    sub new { bless { id => $_[1] }, $_[0] }
    sub id { $_[0]{id} }
    sub master { $_[0] }
}

my $root = tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::values{server}{cachedir} = $root;
$Slim::Utils::Prefs::values{server}{httpport} = 9000;
$Slim::Utils::Prefs::values{'plugin.spoton'}{diagnosticMode} = 1;

my $base = catdir($root, 'spoton', 'soloist-managed');
make_path($base, { mode => 0700 });
my $key_file = catfile($base, 'api-key');
open(my $key_fh, '>', $key_file) or die "Cannot create API key fixture: $!";
print {$key_fh} 'manager-secret-key';
close($key_fh);
chmod 0600, $key_file;

my @registered;
my @unregistered;
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::StreamServer::init = sub { 1 };
    ok(Plugins::SpotOn::Soloist::Manager->init(), 'manager initializes stream surface');
}

{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Transport::websocket_available = sub { 1 };
    local *Plugins::SpotOn::Soloist::AudioPreflight::inspect = sub {
        return {
            tools => {
                soloist    => '/usr/local/bin/soloist',
                pulseaudio => '/usr/bin/pulseaudio',
                parec      => '/usr/bin/parec',
                ffmpeg     => '/usr/bin/ffmpeg',
            },
        };
    };
    local *Plugins::SpotOn::Soloist::Runtime::new = \&Local::Runtime::new;
    local *Plugins::SpotOn::Soloist::Session::new = \&Local::Session::new;
    local *Plugins::SpotOn::Soloist::Manager::_random_token = sub {
        return '0123456789abcdef01234567';
    };
    local *Plugins::SpotOn::Soloist::StreamServer::register_runtime = sub {
        my ($class, $token, $factory) = @_;
        push @registered, [$token, 'flac', $factory];
        return "/plugins/SpotOn/soloist/stream/$token.flac";
    };
    local *Plugins::SpotOn::Soloist::StreamServer::register_runtime_format = sub {
        my ($class, $token, $format, $factory) = @_;
        push @registered, [$token, $format, $factory];
        my $suffix = $format eq 'pcm' ? 'soc' : $format;
        return "/plugins/SpotOn/soloist/stream/$token.$suffix";
    };
    local *Plugins::SpotOn::Soloist::StreamServer::unregister_runtime = sub {
        push @unregistered, $_[1];
        return 1;
    };

    ok(Plugins::SpotOn::Soloist::Manager->start(), 'manager accepts explicit start');
    my $starting = Plugins::SpotOn::Soloist::Manager->statusSnapshot();
    is($starting->{state}, 'starting', 'manager starts asynchronously');
    ok($starting->{apiKeyReady}, 'status reports protected API key file readiness');
    unlike(
        join(' ', @{ $starting->{runtime}{soloistArgv} || [] }),
        qr/manager-secret-key/,
        'status never exposes API key',
    );
    is(
        $Local::Runtime::instances[-1]{args}{device_name},
        'SpotOn Soloist Managed Test',
        'manager uses an isolated diagnostic Connect name',
    );
    is(
        $Local::Runtime::instances[-1]{args}{initial_volume},
        100,
        'managed capture starts full scale to avoid double attenuation',
    );
    ok(@Slim::Utils::Timers::set, 'startup schedules nonblocking poll');

    Plugins::SpotOn::Soloist::Manager::_poll();
    my $running = Plugins::SpotOn::Soloist::Manager->statusSnapshot();
    is($running->{state}, 'running', 'ready runtime transitions manager to running');
    is($running->{sessionStatus}, 'connected', 'manager attaches WebSocket session');
    is(
        $running->{streamPath},
        '/plugins/SpotOn/soloist/stream/0123456789abcdef01234567.flac',
        'manager registers tokenized LMS stream path',
    );
    is(scalar @registered, 2, 'runtime registers FLAC and PCM stream variants');
    isa_ok($registered[0][2]->(), 'Local::Pipeline', 'FLAC stream factory delegates to running runtime');
    isa_ok($registered[1][2]->(), 'Local::Pipeline', 'PCM stream factory delegates to running runtime');
    is_deeply(
        \@Local::Runtime::pipeline_formats,
        ['flac', 'pcm'],
        'each stream factory requests its explicit pipeline format',
    );
    is(
        $running->{streamPaths}{pcm},
        '/plugins/SpotOn/soloist/stream/0123456789abcdef01234567.soc',
        'manager reports the low-latency PCM path separately',
    );
    is(
        Plugins::SpotOn::Soloist::Manager->resolveStreamPath(
            '0123456789abcdef01234567', 'pcm'
        ),
        '/plugins/SpotOn/soloist/stream/0123456789abcdef01234567.soc',
        'active PCM token resolves to the registered route',
    );
    ok(
        !Plugins::SpotOn::Soloist::Manager->resolveStreamPath(
            'aaaaaaaaaaaaaaaaaaaaaaaa', 'pcm'
        ),
        'a stale or guessed PCM token is rejected',
    );
    isa_ok(
        Plugins::SpotOn::Soloist::Manager->newStreamPipeline(
            '0123456789abcdef01234567', 'pcm'
        ),
        'Local::Pipeline',
        'active token creates a direct PCM capture pipeline',
    );
    ok(
        !Plugins::SpotOn::Soloist::Manager->newStreamPipeline(
            'aaaaaaaaaaaaaaaaaaaaaaaa', 'pcm'
        ),
        'stale token cannot create a direct capture pipeline',
    );

    $Local::Session::instances[-1]{args}{on_error}->(
        'connect_failed', 'transient websocket failure'
    );
    is(
        Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError}{code},
        'session_connect_failed',
        'session callback reports a transient connection failure',
    );
    $Local::Session::instances[-1]{args}{on_status}->('connected');
    ok(
        !Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError},
        'successful reconnect clears resolved session transport errors',
    );

    my $player = Local::Player->new('00:11:22:33:44:55');
    ok(
        Plugins::SpotOn::Soloist::Manager->attachPlayer($player),
        'explicit diagnostic action attaches one LMS player',
    );
    my $play_request = $Slim::Control::Request::requests[-1];
    is($play_request->{client_id}, '00:11:22:33:44:55', 'player request targets the selected LMS player');
    is_deeply(
        $play_request->{command},
        [
            'playlist',
            'play',
            'http://192.0.2.10:9000/plugins/SpotOn/soloist/stream/0123456789abcdef01234567.flac',
            'SpotOn Soloist Managed Test',
        ],
        'player receives only the LMS-generated tokenized FLAC URL',
    );
    ok($play_request->{executed}, 'player play request is executed');
    my $player_status = Plugins::SpotOn::Soloist::Manager->statusSnapshot();
    ok($player_status->{playerAttached}, 'status exposes diagnostic player attachment');
    is($player_status->{playerId}, '00:11:22:33:44:55', 'status identifies attached player');

    ok(Plugins::SpotOn::Soloist::Manager->detachPlayer(), 'diagnostic player detaches explicitly');
    is_deeply(
        $Slim::Control::Request::requests[-1]{command},
        ['stop'],
        'detach issues a bounded stop to the attached player',
    );
    ok(
        !Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{playerAttached},
        'detach clears player attachment status',
    );

    ok(
        Plugins::SpotOn::Soloist::Manager->attachPlayer($player, format => 'pcm'),
        'explicit diagnostic action can select low-latency PCM',
    );
    is_deeply(
        $Slim::Control::Request::requests[-1]{command},
        [
            'playlist',
            'play',
            'spoton://soloist-pcm:0123456789abcdef01234567',
            'SpotOn Soloist Managed Test',
        ],
        'PCM handoff uses SpotOn logical protocol for LMS transcoding',
    );
    is(
        Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{playerStreamFormat},
        'pcm',
        'status identifies the selected player stream format',
    );
    ok(Plugins::SpotOn::Soloist::Manager->detachPlayer(), 'PCM player detaches explicitly');

    ok(Plugins::SpotOn::Soloist::Manager->stop(), 'manager stops explicitly');
    is($Local::Runtime::instances[-1]{stopped}, 1, 'stop terminates managed runtime');
    is($Local::Session::instances[-1]{stopped}, 1, 'stop detaches WebSocket session');
    is_deeply(\@unregistered, ['0123456789abcdef01234567'], 'stop revokes stream route');
    is(Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{state}, 'stopped', 'stop clears manager state');

    {
        no warnings 'redefine';
        local *Local::Runtime::start = sub {
            my ($self) = @_;
            $self->{state} = 'failed';
            $self->{last_error} = {
                code    => 'pulse_spawn_failed',
                message => 'PulseAudio child setup failed',
            };
            return 0;
        };

        ok(!Plugins::SpotOn::Soloist::Manager->start(), 'runtime rejection fails managed start');
        my $failed = Plugins::SpotOn::Soloist::Manager->statusSnapshot();
        is(
            $failed->{lastError}{code},
            'runtime_pulse_spawn_failed',
            'manager preserves the concrete runtime failure code',
        );
        is(
            $failed->{lastError}{message},
            'PulseAudio child setup failed',
            'manager preserves the concrete runtime failure message',
        );
    }
    Plugins::SpotOn::Soloist::Manager->stop();
}

unlink($key_file);
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Transport::websocket_available = sub { 1 };
    ok(!Plugins::SpotOn::Soloist::Manager->start(), 'missing API key fails closed');
    is(
        Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError}{code},
        'api_key_missing',
        'missing key has stable error code',
    );
}
Plugins::SpotOn::Soloist::Manager->stop();

open($key_fh, '>', $key_file) or die "Cannot recreate API key fixture: $!";
print {$key_fh} 'manager-secret-key';
close($key_fh);
chmod 0644, $key_file;
ok(!Plugins::SpotOn::Soloist::Manager->start(), 'world-readable API key fails closed');
is(
    Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError}{code},
    'api_key_permissions',
    'insecure key mode has stable error code',
);
Plugins::SpotOn::Soloist::Manager->stop();

my $symlink_cache = tempdir(CLEANUP => 1);
my $symlink_spoton = catdir($symlink_cache, 'spoton');
my $symlink_target = catdir($symlink_cache, 'target');
make_path($symlink_spoton, { mode => 0700 });
make_path($symlink_target, { mode => 0700 });
symlink($symlink_target, catdir($symlink_spoton, 'soloist-managed'))
    or die "Cannot create manager symlink fixture: $!";
$Slim::Utils::Prefs::values{server}{cachedir} = $symlink_cache;
ok(!Plugins::SpotOn::Soloist::Manager->start(), 'symlinked managed base directory fails closed');
is(
    Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError}{code},
    'base_dir_failed',
    'unsafe managed base has stable error code',
);
Plugins::SpotOn::Soloist::Manager->stop();
$Slim::Utils::Prefs::values{server}{cachedir} = $root;

done_testing();

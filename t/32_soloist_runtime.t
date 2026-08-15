#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Runtime;

{
    package Local::Process;

    our $next_pid = 3000;
    our @terminated;

    sub new {
        my ($class, $kind) = @_;
        return bless {
            kind  => $kind,
            alive => 1,
            pid   => ++$next_pid,
        }, $class;
    }

    sub alive { $_[0]{alive} }
    sub pid   { $_[0]{pid} }
    sub die {
        my ($self) = @_;
        push @terminated, $self->{kind};
        $self->{alive} = 0;
    }
}

sub mode_of {
    return (stat($_[0]))[2] & 07777;
}

my $root = tempdir(CLEANUP => 1);
my $runtime_dir = catdir($root, 'runtime');
my $data_dir = catdir($root, 'data');
my $cache_dir = catdir($root, 'cache');
my $log_dir = catdir($root, 'logs');
my $now = 100;
my $socket_ready = 0;
my $endpoint_ready = 0;
my @spawns;

my $spawn = sub {
    my ($kind, $spec, $stdout, $stderr) = @_;
    push @spawns, {
        kind => $kind,
        spec => $spec,
    };
    return Local::Process->new($kind);
};

my $runtime = Plugins::SpotOn::Soloist::Runtime->new(
    api_key           => 'top-secret-api-key',
    device_name       => 'SpotOn Soloist Test',
    soloist_binary    => '/opt/soloist/soloist',
    pulseaudio_binary => '/usr/bin/pulseaudio',
    parec_binary      => '/usr/bin/parec',
    ffmpeg_binary     => '/usr/bin/ffmpeg',
    runtime_dir       => $runtime_dir,
    data_dir          => $data_dir,
    cache_dir         => $cache_dir,
    log_dir           => $log_dir,
    clock             => sub { $now },
    random_bytes      => sub { return 'R' x $_[0] },
    socket_ready      => sub { $socket_ready },
    endpoint_discover => sub {
        return (undef, 'not_ready') unless $endpoint_ready;
        return ({
            url      => 'ws://127.0.0.1:19090',
            address  => '127.0.0.1',
            port     => 19090,
            pid      => 4242,
            data_dir => $data_dir,
        }, undef);
    },
    spawn => $spawn,
);

is($runtime->state(), 'stopped', 'runtime starts stopped');
ok($runtime->start(), 'runtime accepts explicit start');
is($runtime->state(), 'starting_pulse', 'PulseAudio starts before Soloist');
is_deeply([ map { $_->{kind} } @spawns ], ['pulse'], 'only PulseAudio is spawned initially');

for my $directory ($runtime_dir, catdir($runtime_dir, 'config'),
    catdir($runtime_dir, 'config', 'pulse'), $data_dir, $cache_dir, $log_dir) {
    ok(-d $directory, "runtime directory exists: $directory");
    is(mode_of($directory), 0700, "runtime directory is private: $directory");
}

my $cookie = catfile($runtime_dir, 'config', 'pulse', 'cookie');
is(-s $cookie, 256, 'PulseAudio cookie has the required size');
is(mode_of($cookie), 0600, 'PulseAudio cookie is private');

is(
    $spawns[0]{spec}{env}{PULSE_COOKIE},
    $cookie,
    'PulseAudio server uses the securely prepared cookie',
);
is(
    $spawns[0]{spec}{env}{PULSE_SERVER},
    'unix:' . catfile($runtime_dir, 'native'),
    'PulseAudio server uses the private runtime socket',
);

is($runtime->poll(), 'starting_pulse', 'runtime waits asynchronously for Pulse socket');
$socket_ready = 1;
is($runtime->poll(), 'starting_soloist', 'ready Pulse socket starts Soloist');
is_deeply(
    [ map { $_->{kind} } @spawns ],
    ['pulse', 'soloist'],
    'Soloist is spawned only after PulseAudio readiness',
);
is_deeply(
    $spawns[1]{spec}{env},
    {
        PULSE_SERVER => 'unix:' . catfile($runtime_dir, 'native'),
        PULSE_COOKIE => $cookie,
    },
    'Soloist receives the private Pulse connection pair',
);

my $starting = $runtime->status_snapshot();
unlike(
    join(' ', @{ $starting->{soloistArgv} }),
    qr/top-secret-api-key/,
    'status snapshot never exposes the API key',
);
like(
    join(' ', @{ $starting->{soloistArgv} }),
    qr/\[REDACTED\]/,
    'status snapshot explicitly redacts the API key',
);

is($runtime->poll(), 'starting_soloist', 'runtime waits for Soloist endpoint files');
$endpoint_ready = 1;
is($runtime->poll(), 'running', 'loopback endpoint marks runtime running');
is($runtime->endpoint()->{port}, 19090, 'running runtime exposes normalized endpoint');

require Plugins::SpotOn::Soloist::StreamPipeline;
my $pipeline_args;
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::StreamPipeline::new = sub {
        my ($class, %args) = @_;
        $pipeline_args = \%args;
        return bless {}, 'Local::BuiltPipeline';
    };
    ok($runtime->new_stream_pipeline(), 'running runtime builds its stream pipeline');
}
is(
    $pipeline_args->{capture_spec}{env}{PULSE_COOKIE},
    $cookie,
    'runtime stream capture reuses the private Pulse cookie',
);
like(
    join(' ', @{ $pipeline_args->{capture_spec}{argv} }),
    qr/spoton_soloist\.monitor/,
    'runtime stream capture reads its isolated monitor',
);
is(
    $pipeline_args->{encoder_spec}{output_format},
    'flac',
    'runtime stream pipeline encodes FLAC for LMS',
);

@Local::Process::terminated = ();
ok($runtime->stop(), 'runtime stops cleanly');
is_deeply(
    \@Local::Process::terminated,
    ['soloist', 'pulse'],
    'shutdown terminates Soloist before its PulseAudio server',
);
is($runtime->state(), 'stopped', 'runtime returns to stopped state');

my $timeout_root = tempdir(CLEANUP => 1);
my $timeout_now = 10;
my $timeout_runtime = Plugins::SpotOn::Soloist::Runtime->new(
    api_key            => 'key',
    device_name        => 'Timeout Probe',
    soloist_binary     => '/opt/soloist/soloist',
    pulseaudio_binary  => '/usr/bin/pulseaudio',
    runtime_dir        => catdir($timeout_root, 'runtime'),
    data_dir           => catdir($timeout_root, 'data'),
    cache_dir          => catdir($timeout_root, 'cache'),
    log_dir            => catdir($timeout_root, 'logs'),
    pulse_start_timeout => 2,
    clock              => sub { $timeout_now },
    random_bytes       => sub { return 'X' x $_[0] },
    socket_ready       => sub { 0 },
    spawn              => sub { Local::Process->new($_[0]) },
);
ok($timeout_runtime->start(), 'timeout fixture starts');
$timeout_now = 12;
ok(!$timeout_runtime->poll(), 'Pulse startup timeout fails closed');
is($timeout_runtime->state(), 'failed', 'timeout enters failed state');
is(
    $timeout_runtime->last_error()->{code},
    'pulse_start_timeout',
    'timeout has a stable diagnostic code',
);

my $unsafe_root = tempdir(CLEANUP => 1);
my $unsafe_runtime = Plugins::SpotOn::Soloist::Runtime->new(
    api_key           => 'key',
    device_name       => 'Unsafe Endpoint Probe',
    soloist_binary    => '/opt/soloist/soloist',
    pulseaudio_binary => '/usr/bin/pulseaudio',
    runtime_dir       => catdir($unsafe_root, 'runtime'),
    data_dir          => catdir($unsafe_root, 'data'),
    cache_dir         => catdir($unsafe_root, 'cache'),
    log_dir           => catdir($unsafe_root, 'logs'),
    random_bytes      => sub { return 'Y' x $_[0] },
    socket_ready      => sub { 1 },
    endpoint_discover => sub { return (undef, 'unsafe_address') },
    spawn              => sub { Local::Process->new($_[0]) },
);
ok($unsafe_runtime->start(), 'unsafe endpoint fixture starts');
is($unsafe_runtime->poll(), 'starting_soloist', 'unsafe fixture reaches Soloist startup');
ok(!$unsafe_runtime->poll(), 'unsafe WebSocket endpoint fails closed');
is(
    $unsafe_runtime->last_error()->{code},
    'endpoint_unsafe_address',
    'unsafe endpoint has a stable diagnostic code',
);

my $symlink_root = tempdir(CLEANUP => 1);
my $real_runtime = catdir($symlink_root, 'real');
mkdir($real_runtime, 0700) or die "Cannot create symlink fixture: $!";
my $linked_runtime = catdir($symlink_root, 'linked');
symlink($real_runtime, $linked_runtime) or die "Cannot create symlink fixture: $!";
my $symlink_runtime = Plugins::SpotOn::Soloist::Runtime->new(
    api_key           => 'key',
    device_name       => 'Symlink Probe',
    soloist_binary    => '/opt/soloist/soloist',
    pulseaudio_binary => '/usr/bin/pulseaudio',
    runtime_dir       => $linked_runtime,
    data_dir          => catdir($symlink_root, 'data'),
    cache_dir         => catdir($symlink_root, 'cache'),
    log_dir           => catdir($symlink_root, 'logs'),
    random_bytes      => sub { return 'Z' x $_[0] },
    spawn              => sub { Local::Process->new($_[0]) },
);
ok(!$symlink_runtime->start(), 'symlinked runtime directory is rejected');
is(
    $symlink_runtime->last_error()->{code},
    'runtime_prepare_failed',
    'unsafe layout has a stable failure code',
);

my $log_symlink_root = tempdir(CLEANUP => 1);
my $log_symlink_dir = catdir($log_symlink_root, 'logs');
mkdir($log_symlink_dir, 0700) or die "Cannot create log fixture: $!";
my $log_target = catfile($log_symlink_root, 'target');
open(my $log_target_fh, '>', $log_target) or die "Cannot create log target: $!";
close($log_target_fh);
symlink($log_target, catfile($log_symlink_dir, 'pulse.log'))
    or die "Cannot create log symlink fixture: $!";
my $log_symlink_runtime = Plugins::SpotOn::Soloist::Runtime->new(
    api_key           => 'key',
    device_name       => 'Log Symlink Probe',
    soloist_binary    => '/opt/soloist/soloist',
    pulseaudio_binary => '/usr/bin/pulseaudio',
    runtime_dir       => catdir($log_symlink_root, 'runtime'),
    data_dir          => catdir($log_symlink_root, 'data'),
    cache_dir         => catdir($log_symlink_root, 'cache'),
    log_dir           => $log_symlink_dir,
    random_bytes      => sub { return 'L' x $_[0] },
    spawn              => sub { Local::Process->new($_[0]) },
);
ok(!$log_symlink_runtime->start(), 'symlinked runtime log is rejected');
is(
    $log_symlink_runtime->last_error()->{code},
    'log_open_failed',
    'unsafe log has a stable failure code',
);
is(-s $log_target, 0, 'symlink target was not opened or modified');

{
    package Slim::Utils::Log::Trapper;
    sub TIEHANDLE { bless {}, shift }
    sub PRINT { 1 }

    package Proc::Background;
    our $stderr_was_tied;
    our $pulse_server;
    sub new {
        my ($class, $options, @argv) = @_;
        $stderr_was_tied = defined tied(*STDERR) ? 1 : 0;
        $pulse_server = $ENV{PULSE_SERVER};
        return Local::Process->new('default-spawn');
    }
}
$INC{'Proc/Background.pm'} = __FILE__;

my $spawn_log = '';
open(my $spawn_log_fh, '>', \$spawn_log) or die "Cannot create spawn log handle: $!";
tie *STDERR, 'Slim::Utils::Log::Trapper';
my $default_process = Plugins::SpotOn::Soloist::Runtime::_spawn_process(
    'pulse',
    {
        argv => ['/usr/bin/pulseaudio', '--daemonize=no'],
        env  => { PULSE_SERVER => 'unix:/tmp/spoton-test-native' },
    },
    $spawn_log_fh,
    $spawn_log_fh,
);
ok($default_process, 'default process launcher returns the background process');
ok(!$Proc::Background::stderr_was_tied, 'default launcher unties LMS STDERR during child setup');
is(
    $Proc::Background::pulse_server,
    'unix:/tmp/spoton-test-native',
    'default launcher passes the private Pulse environment',
);
isa_ok(
    tied(*STDERR),
    'Slim::Utils::Log::Trapper',
    'default launcher restores the LMS STDERR trapper',
);
untie *STDERR;
close($spawn_log_fh);

my $redaction_root = tempdir(CLEANUP => 1);
my $redaction_runtime = Plugins::SpotOn::Soloist::Runtime->new(
    api_key           => 'runtime-secret-value',
    device_name       => 'Redaction Probe',
    soloist_binary    => '/opt/soloist/soloist',
    pulseaudio_binary => '/usr/bin/pulseaudio',
    runtime_dir       => catdir($redaction_root, 'runtime'),
    data_dir          => catdir($redaction_root, 'data'),
    cache_dir         => catdir($redaction_root, 'cache'),
    log_dir           => catdir($redaction_root, 'logs'),
    random_bytes      => sub { return 'S' x $_[0] },
    spawn              => sub { die 'spawn rejected runtime-secret-value' },
);
ok(!$redaction_runtime->start(), 'spawn exception fails runtime start');
unlike(
    $redaction_runtime->last_error()->{message},
    qr/runtime-secret-value/,
    'runtime failure message redacts the API key',
);
like(
    $redaction_runtime->last_error()->{message},
    qr/\[REDACTED\]/,
    'runtime failure message marks the redacted value',
);

done_testing();

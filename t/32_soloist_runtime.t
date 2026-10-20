#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use File::Spec::Functions qw(catdir catfile);
use File::Path ();
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
        PULSE_SERVER       => 'unix:' . catfile($runtime_dir, 'native'),
        PULSE_COOKIE       => $cookie,
        PULSE_LATENCY_MSEC => '400',
    },
    'Soloist receives the private Pulse connection and 400 ms playback request',
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

{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::StreamPipeline::new = sub {
        my ($class, %args) = @_;
        $pipeline_args = \%args;
        return bless {}, 'Local::BuiltPipeline';
    };
    ok(
        $runtime->new_stream_pipeline('pcm'),
        'running runtime builds a low-latency PCM pipeline',
    );
}
is(
    $pipeline_args->{encoder_spec},
    undef,
    'PCM pipeline bypasses the FLAC encoder',
);

my $bad_stream_format = eval {
    $runtime->new_stream_pipeline('mp3');
    '';
} || $@;
like(
    $bad_stream_format,
    qr/stream format must be flac or pcm/,
    'runtime rejects unsupported stream formats',
);

my $daemon_conf = catfile($runtime_dir, 'config', 'pulse', 'daemon.conf');
open(my $conf_fh, '<', $daemon_conf) or die "daemon.conf missing: $!";
like(do { local $/; <$conf_fh> }, qr/^flat-volumes = no$/m, 'private PulseAudio disables flat volumes');
close($conf_fh);
is(mode_of($daemon_conf), 0600, 'private daemon.conf is owner-only');

# Volume compensation: the sink gets the inverse of Soloist's stream volume.
{
    my @commands;
    my $listing = join('',
        "Sink Input #3\n\tDriver: protocol-native.c\n\tVolume: front-left: 65536 / 100% / 0.00 dB,   front-right: 65536 / 100% / 0.00 dB\n",
        "Sink Input #7\n\tDriver: protocol-native.c\n\tVolume: front-left: 19660 /  30% / -31.37 dB,   front-right: 19660 /  30% / -31.37 dB\n",
    );
    local $runtime->{pactl_binary} = '/usr/bin/pactl';
    local $runtime->{run_command} = sub {
        my ($argv, $env) = @_;
        push @commands, [[@$argv], {%$env}];
        return $argv->[1] eq 'list' ? $listing : '';
    };
    ok($runtime->compensate_volume(), 'volume compensation succeeds');
    is_deeply($commands[-1][0], ['/usr/bin/pactl', 'set-sink-volume', 'spoton_soloist', 218462],
        'sink volume is the inverse of the newest Soloist stream volume');
    is($commands[0][1]{LC_ALL}, 'C', 'pactl output is parsed in the C locale');
    is($commands[0][1]{PULSE_SERVER}, 'unix:' . catfile($runtime_dir, 'native'), 'pactl uses the private server');

    @commands = ();
    $runtime->compensate_volume();
    is(scalar @commands, 1, 'unchanged stream volume does not touch the sink again');

    $listing = "Sink Input #8\n\tVolume: front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB\n";
    @commands = ();
    $runtime->compensate_volume();
    is($commands[-1][0][3], 65536, 'muted stream resets the sink to 100%');

    $listing = '';
    @commands = ();
    $runtime->compensate_volume();
    is(scalar @commands, 1, 'no stream keeps the current sink volume');
}

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

# A crashed LMS leaves its children and Soloist's runtime files behind.  The
# next start must terminate exactly those processes and remove stale files
# before PulseAudio readiness or endpoint discovery can be trusted.
{
    my $stale_root = tempdir(CLEANUP => 1);
    my $stale_runtime_dir = catdir($stale_root, 'runtime');
    my $stale_data_dir = catdir($stale_root, 'data');
    my $proc_root = catdir($stale_root, 'proc');
    my $socket = catfile($stale_runtime_dir, 'native');
    my %cmdlines = (
        4101 => ['/usr/bin/pulseaudio', '--daemonize=no', '--load',
            "module-native-protocol-unix socket=$socket auth-cookie=/x"],
        4102 => ['/opt/soloist/soloist', '--device-name', 'Kitchen',
            '--data-dir', $stale_data_dir, '--ws', '127.0.0.1:0'],
        4103 => ['/usr/bin/parec', '--record', '--server', "unix:$socket"],
        4104 => ['/opt/soloist/soloist', '--data-dir', '/elsewhere/data'],
        4105 => ['/usr/bin/pulseaudio', '--load',
            'module-native-protocol-unix socket=/elsewhere/native auth-cookie=/x'],
    );
    for my $pid (keys %cmdlines) {
        my $dir = catdir($proc_root, $pid);
        File::Path::make_path($dir);
        open(my $fh, '>', catfile($dir, 'cmdline')) or die $!;
        print {$fh} join("\0", @{ $cmdlines{$pid} }), "\0";
        close($fh);
    }
    File::Path::make_path($stale_runtime_dir, $stale_data_dir, { mode => 0700 });
    for my $file (map { catfile($stale_data_dir, $_) } qw(ws.addr ws.port soloist.pid)) {
        open(my $fh, '>', $file) or die $!;
        print {$fh} "stale\n";
        close($fh);
    }
    open(my $sock_fh, '>', $socket) or die $!;
    close($sock_fh);

    my %alive = map { $_ => 1 } keys %cmdlines;
    my @signals;
    my $stale_now = 50;
    my $stale = Plugins::SpotOn::Soloist::Runtime->new(
        api_key           => 'key',
        device_name       => 'Stale Probe',
        soloist_binary    => '/opt/soloist/soloist',
        pulseaudio_binary => '/usr/bin/pulseaudio',
        runtime_dir       => $stale_runtime_dir,
        data_dir          => $stale_data_dir,
        cache_dir         => catdir($stale_root, 'cache'),
        log_dir           => catdir($stale_root, 'logs'),
        proc_root         => $proc_root,
        clock             => sub { $stale_now },
        sleep             => sub { $stale_now += $_[0] },
        random_bytes      => sub { return 'O' x $_[0] },
        signal_process    => sub {
            my ($signal, $pid) = @_;
            push @signals, [$signal, $pid] if $signal;
            # The Soloist orphan ignores TERM and needs KILL.
            delete $alive{$pid} if $signal eq 'KILL'
                || ($signal eq 'TERM' && $pid != 4102);
            return $alive{$pid} ? 1 : 0;
        },
        spawn             => sub { Local::Process->new($_[0]) },
    );
    ok($stale->start(), 'runtime starts after an unclean previous shutdown');
    is_deeply(
        [ sort { $a <=> $b } map { $_->[1] } grep { $_->[0] eq 'TERM' } @signals ],
        [4101, 4102, 4103],
        'only processes owning this runtime socket or data directory are terminated',
    );
    is_deeply(
        [ grep { $_->[0] eq 'KILL' } @signals ],
        [['KILL', 4102]],
        'an orphan ignoring TERM is killed after the grace period',
    );
    ok(!-e $socket, 'stale PulseAudio socket is removed before readiness polling');
    ok(!-e catfile($stale_data_dir, $_), "stale Soloist $_ is removed")
        for qw(ws.addr ws.port soloist.pid);
    $stale->stop();
}

# Soloist documents exit code 10 for an expired build.  Report it distinctly
# instead of as a generic crash so the manager can stop hammering restarts.
{
    package Local::ExitedProcess;
    our @ISA = ('Local::Process');
    sub new {
        my ($class, $kind, $code) = @_;
        my $self = Local::Process::new($class, $kind);
        $self->{exit_code} = $code;
        return $self;
    }
    sub exit_code { $_[0]{alive} ? undef : $_[0]{exit_code} }
}
for my $case ([10, 'soloist_build_expired'], [1, 'soloist_exited']) {
    my ($code, $expected) = @$case;
    my $exit_root = tempdir(CLEANUP => 1);
    my $soloist_proc;
    my $exit_runtime = Plugins::SpotOn::Soloist::Runtime->new(
        api_key           => 'exit-secret-key',
        device_name       => 'Exit Probe',
        soloist_binary    => '/opt/soloist/soloist',
        pulseaudio_binary => '/usr/bin/pulseaudio',
        runtime_dir       => catdir($exit_root, 'runtime'),
        data_dir          => catdir($exit_root, 'data'),
        cache_dir         => catdir($exit_root, 'cache'),
        log_dir           => catdir($exit_root, 'logs'),
        proc_root         => catdir($exit_root, 'no-proc'),
        random_bytes      => sub { return 'E' x $_[0] },
        socket_ready      => sub { 1 },
        endpoint_discover => sub { return (undef, 'not_ready') },
        spawn             => sub {
            my ($kind, $spec, $stdout) = @_;
            return Local::Process->new($kind) unless $kind eq 'soloist';
            syswrite($stdout, "starting with exit-secret-key\nerror: another process holds the data directory\n");
            $soloist_proc = Local::ExitedProcess->new($kind, $code);
            return $soloist_proc;
        },
    );
    ok($exit_runtime->start(), "exit-code $code fixture starts");
    is($exit_runtime->poll(), 'starting_soloist', "exit-code $code fixture spawns Soloist");
    $soloist_proc->{alive} = 0;
    ok(!$exit_runtime->poll(), "Soloist exit code $code fails the runtime");
    is($exit_runtime->last_error()->{code}, $expected, "exit code $code maps to $expected");
    if ($code == 1) {
        like(
            $exit_runtime->last_error()->{message},
            qr/exit code 1.*another process holds the data directory/,
            'generic Soloist exit reports its exit code and log tail',
        );
        unlike(
            $exit_runtime->last_error()->{message},
            qr/exit-secret-key/,
            'log tail in failure message is redacted',
        );
    }
}

done_testing();

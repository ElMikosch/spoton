#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::PulseBridgeSpec qw(
    build_capture_spec
    build_encoder_spec
    build_server_spec
);

sub dies_like {
    my ($code, $pattern, $name) = @_;
    my $error = eval { $code->(); 1 } ? '' : $@;
    like($error, $pattern, $name);
}

my $socket = '/var/cache/lyrion/spoton/pulse/native';
my $server = build_server_spec(
    binary     => '/usr/bin/pulseaudio',
    socket_path => $socket,
    sink_name  => 'spoton_soloist',
);

is($server->{monitor}, 'spoton_soloist.monitor', 'null sink monitor name is deterministic');
is($server->{env}{PULSE_SERVER}, "unix:$socket", 'server exports the isolated socket address');
is_deeply(
    [ @{ $server->{argv} }[-4 .. -1] ],
    [
        '--load',
        "module-native-protocol-unix socket=$socket auth-anonymous=1",
        '--load',
        'module-null-sink sink_name=spoton_soloist rate=44100 channels=2',
    ],
    'server loads only a private native socket and null sink',
);
ok(
    (grep { $_ eq '--daemonize=no' } @{ $server->{argv} }),
    'server remains supervised in the foreground',
);
ok(
    (grep { $_ eq '--disallow-module-loading=yes' } @{ $server->{argv} }),
    'server prevents runtime module injection',
);

my $capture = build_capture_spec(
    binary      => '/usr/bin/parec',
    socket_path => $socket,
    sink_name   => 'spoton_soloist',
    latency_ms  => 80,
);
is_deeply(
    $capture->{argv},
    [
        '/usr/bin/parec',
        '--server', "unix:$socket",
        '--device', 'spoton_soloist.monitor',
        '--format', 's16le',
        '--rate', 44_100,
        '--channels', 2,
        '--latency-msec', 80,
        '--raw',
        '--client-name', 'SpotOn-Soloist-Capture',
        '--stream-name', 'SpotOn Soloist PCM',
    ],
    'capture reads deterministic raw PCM from the null-sink monitor',
);

my $encoder = build_encoder_spec(binary => '/usr/bin/ffmpeg');
is_deeply(
    $encoder->{argv},
    [
        '/usr/bin/ffmpeg',
        '-nostdin',
        '-hide_banner',
        '-loglevel', 'warning',
        '-f', 's16le',
        '-ar', 44_100,
        '-ac', 2,
        '-i', 'pipe:0',
        '-map_metadata', '-1',
        '-vn',
        '-c:a', 'flac',
        '-f', 'flac',
        'pipe:1',
    ],
    'encoder turns capture PCM into an LMS-compatible FLAC stream',
);
is($encoder->{output_format}, 'flac', 'encoder declares FLAC output');

dies_like(
    sub { build_server_spec(
        binary      => '/usr/bin/pulseaudio',
        socket_path => '/tmp/pulse socket/native',
    ) },
    qr/socket_path contains unsupported characters/,
    'module argument injection through socket whitespace is rejected',
);

dies_like(
    sub { build_server_spec(
        binary      => '/usr/bin/pulseaudio',
        socket_path => '/tmp/pulse/native',
        sink_name   => 'sink auth-anonymous=1',
    ) },
    qr/sink_name must use/,
    'module argument injection through sink name is rejected',
);

dies_like(
    sub { build_capture_spec(
        binary      => '/usr/bin/parec',
        socket_path => '/tmp/pulse/native',
        latency_ms  => 5,
    ) },
    qr/latency_ms must be between 20 and 2000/,
    'unrealistic capture latency is rejected',
);

dies_like(
    sub { build_encoder_spec(
        binary      => '/usr/bin/ffmpeg',
        sample_rate => 44_100,
        shell       => '/bin/sh',
    ) },
    qr/Unsupported Pulse bridge option: shell/,
    'unsupported process options are rejected',
);

done_testing();

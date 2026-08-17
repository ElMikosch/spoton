#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::ProcessSpec qw(build_process_spec);

sub dies_like {
    my ($code, $pattern, $name) = @_;
    my $error = eval { $code->(); 1 } ? '' : $@;
    like($error, $pattern, $name);
}

my $secret = 'soloist-secret-value';
my $spec = build_process_spec(
    binary          => '/opt/soloist/bin/soloist',
    device_name     => 'SpotOn Kitchen',
    api_key         => $secret,
    data_dir        => '/var/lib/spoton/soloist',
    cache_dir       => '/var/cache/spoton/soloist',
    cache_size      => 512,
    initial_volume  => 37,
    pipewire_device => 'spoton-sink',
    pulse_server    => 'unix:/var/cache/lyrion/spoton/pulse/native',
    pulse_cookie    => '/var/cache/lyrion/spoton/pulse/config/pulse/cookie',
    verbose         => 1,
);

is_deeply(
    $spec->{argv},
    [
        '/opt/soloist/bin/soloist',
        '--device-name', 'SpotOn Kitchen',
        '--api-key', $secret,
        '--data-dir', '/var/lib/spoton/soloist',
        '--cache-dir', '/var/cache/spoton/soloist',
        '--ws', '127.0.0.1:0',
        '--cache-size', 512,
        '--initial-volume', 37,
        '--pipewire-device', 'spoton-sink',
        '--verbose',
    ],
    'process spec maps supported daemon options to an argv array',
);

is_deeply(
    $spec->{env},
    {
        PULSE_SERVER       => 'unix:/var/cache/lyrion/spoton/pulse/native',
        PULSE_COOKIE       => '/var/cache/lyrion/spoton/pulse/config/pulse/cookie',
        PULSE_LATENCY_MSEC => '100',
    },
    'private Pulse connection and low-latency playback request use the process environment',
);
ok(
    !(grep {
        defined $_ && /\A(?:unix:\/var\/cache|\/var\/cache\/lyrion\/spoton\/pulse)/
    } @{ $spec->{argv} }, @{ $spec->{redacted_argv} }),
    'Pulse connection details do not leak into either argument array',
);

is($spec->{websocket_bind}, '127.0.0.1:0', 'WebSocket bind is fixed to loopback');
is_deeply(
    [ grep { $_ eq $secret } @{ $spec->{argv} } ],
    [$secret],
    'runtime argv contains the API key exactly once as required by Soloist',
);
ok(
    !(grep { defined $_ && $_ eq $secret } @{ $spec->{redacted_argv} }),
    'redacted argv contains no API key',
);
is(
    $spec->{redacted_argv}[4],
    '[REDACTED]',
    'redacted argv marks the secret argument explicitly',
);

my $minimal = build_process_spec(
    binary      => 'soloist',
    device_name => 'SpotOn Probe',
    api_key     => 'key',
    data_dir    => '/data',
    cache_dir   => '/cache',
);
is_deeply(
    $minimal->{argv},
    [
        'soloist',
        '--device-name', 'SpotOn Probe',
        '--api-key', 'key',
        '--data-dir', '/data',
        '--cache-dir', '/cache',
        '--ws', '127.0.0.1:0',
    ],
    'optional daemon flags are omitted by default',
);
is_deeply($minimal->{env}, {}, 'Pulse environment is omitted by default');

my $custom_latency = build_process_spec(
    binary           => 'soloist',
    device_name      => 'SpotOn Probe',
    api_key          => 'key',
    data_dir         => '/data',
    cache_dir        => '/cache',
    pulse_server     => 'unix:/run/spoton/native',
    pulse_cookie     => '/run/spoton/config/pulse/cookie',
    pulse_latency_ms => 60,
);
is(
    $custom_latency->{env}{PULSE_LATENCY_MSEC},
    '60',
    'explicit Pulse playback latency is validated and exported',
);

my $unlimited = build_process_spec(
    binary      => 'soloist',
    device_name => 'SpotOn Probe',
    api_key     => 'key',
    data_dir    => '/data',
    cache_dir   => '/cache',
    cache_size  => 0,
);
is_deeply(
    [ @{ $unlimited->{argv} }[-2, -1] ],
    ['--cache-size', 0],
    'cache size zero preserves Soloist unlimited-cache semantics',
);

dies_like(
    sub { build_process_spec(
        binary       => 'soloist',
        device_name  => 'Probe',
        api_key      => 'key',
        data_dir     => '/data',
        cache_dir    => '/cache',
        pulse_server => 'unix:/run/spoton/native',
    ) },
    qr/pulse_server and pulse_cookie must be provided together/,
    'Pulse server cannot be configured without a cookie',
);

dies_like(
    sub { build_process_spec(
        binary       => 'soloist',
        device_name  => 'Probe',
        api_key      => 'key',
        data_dir     => '/data',
        cache_dir    => '/cache',
        pulse_cookie => '/run/spoton/pulse/cookie',
    ) },
    qr/pulse_server and pulse_cookie must be provided together/,
    'Pulse cookie cannot be configured without a server',
);

dies_like(
    sub { build_process_spec(
        binary       => 'soloist',
        device_name  => 'Probe',
        api_key      => 'key',
        data_dir     => '/data',
        cache_dir    => '/cache',
        pulse_server => 'unix:/run/spoton/socket injected',
        pulse_cookie => '/run/spoton/pulse/cookie',
    ) },
    qr/pulse_server must be an absolute Unix socket address/,
    'unsafe Pulse server addresses are rejected',
);

dies_like(
    sub { build_process_spec(
        binary       => 'soloist',
        device_name  => 'Probe',
        api_key      => 'key',
        data_dir     => '/data',
        cache_dir    => '/cache',
        pulse_server => 'unix:/run/spoton/native',
        pulse_cookie => 'relative/cookie',
    ) },
    qr/pulse_cookie must be an absolute path/,
    'relative Pulse cookie paths are rejected',
);

dies_like(
    sub { build_process_spec(
        binary           => 'soloist',
        device_name      => 'Probe',
        api_key          => 'key',
        data_dir         => '/data',
        cache_dir        => '/cache',
        pulse_latency_ms => 100,
    ) },
    qr/pulse_latency_ms requires pulse_server and pulse_cookie/,
    'Pulse latency cannot be configured without a private Pulse connection',
);

dies_like(
    sub { build_process_spec(
        binary           => 'soloist',
        device_name      => 'Probe',
        api_key          => 'key',
        data_dir         => '/data',
        cache_dir        => '/cache',
        pulse_server     => 'unix:/run/spoton/native',
        pulse_cookie     => '/run/spoton/config/pulse/cookie',
        pulse_latency_ms => 19,
    ) },
    qr/pulse_latency_ms must be between 20 and 2000/,
    'unsafe Pulse playback latency is rejected',
);

dies_like(
    sub { build_process_spec(
        binary      => 'soloist',
        device_name => 'Probe',
        data_dir    => '/data',
        cache_dir   => '/cache',
    ) },
    qr/api_key is required/,
    'API key is required',
);

dies_like(
    sub { build_process_spec(
        binary      => 'soloist',
        device_name => "Probe\nInjected",
        api_key     => 'key',
        data_dir    => '/data',
        cache_dir   => '/cache',
    ) },
    qr/device_name contains a control character/,
    'control characters in log-visible values are rejected',
);

dies_like(
    sub { build_process_spec(
        binary         => 'soloist',
        device_name    => 'Probe',
        api_key        => 'key',
        data_dir       => '/data',
        cache_dir      => '/cache',
        initial_volume => 101,
    ) },
    qr/initial_volume must be between 0 and 100/,
    'invalid initial volume is rejected',
);

dies_like(
    sub { build_process_spec(
        binary      => 'soloist',
        device_name => 'Probe',
        api_key     => 'key',
        data_dir    => '/data',
        cache_dir   => '/cache',
        cache_size  => 99,
    ) },
    qr/cache_size must be 0 or at least 100/,
    'cache sizes below the Soloist minimum are rejected',
);

dies_like(
    sub { build_process_spec(
        binary      => 'soloist',
        device_name => 'Probe',
        api_key     => 'key',
        data_dir    => '/data',
        cache_dir   => '/cache',
        ws           => '0.0.0.0:9090',
    ) },
    qr/Unsupported Soloist process option: ws/,
    'caller cannot override the loopback WebSocket policy',
);

done_testing();

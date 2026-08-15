package Plugins::SpotOn::Soloist::PulseBridgeSpec;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use File::Basename qw(dirname);
use File::Spec;

our @EXPORT_OK = qw(
    build_capture_spec
    build_encoder_spec
    build_server_spec
);

use constant DEFAULT_SAMPLE_RATE => 44_100;
use constant DEFAULT_CHANNELS    => 2;
use constant DEFAULT_LATENCY_MS  => 100;

# This module only creates argv/env specifications.  Process ownership,
# readiness checks, pipe wiring, and teardown remain lifecycle concerns.
# None of these commands is passed through a shell.

sub build_server_spec {
    my (%args) = @_;
    _reject_unknown(\%args, qw(binary channels sample_rate sink_name socket_path));

    my $binary = _required_text($args{binary}, 'server binary');
    my $socket = _socket_path($args{socket_path});
    my $runtime_dir = dirname($socket);
    my $config_dir = File::Spec->catdir($runtime_dir, 'config');
    my $cookie_path = File::Spec->catfile($config_dir, 'pulse', 'cookie');
    my $sink = _sink_name($args{sink_name});
    my $rate = _sample_rate($args{sample_rate});
    my $channels = _channels($args{channels});

    return {
        argv => [
            $binary,
            '--daemonize=no',
            '--exit-idle-time=-1',
            '--disallow-exit=yes',
            '--disallow-module-loading=yes',
            '--fail=yes',
            '--high-priority=no',
            '--realtime=no',
            '--use-pid-file=no',
            '--log-target=stderr',
            '--log-level=warning',
            '-n',
            '--load',
            "module-native-protocol-unix socket=$socket auth-cookie=$cookie_path",
            '--load',
            "module-null-sink sink_name=$sink rate=$rate channels=$channels",
        ],
        env => {
            PULSE_SERVER    => "unix:$socket",
            PULSE_COOKIE    => $cookie_path,
            XDG_CONFIG_HOME => $config_dir,
            XDG_RUNTIME_DIR => $runtime_dir,
        },
        socket_path  => $socket,
        runtime_dir  => $runtime_dir,
        config_dir   => $config_dir,
        cookie_path  => $cookie_path,
        sink_name    => $sink,
        monitor      => "$sink.monitor",
        sample_rate  => $rate,
        channels     => $channels,
    };
}

sub build_capture_spec {
    my (%args) = @_;
    _reject_unknown(
        \%args,
        qw(binary channels latency_ms sample_rate sink_name socket_path),
    );

    my $binary = _required_text($args{binary}, 'capture binary');
    my $socket = _socket_path($args{socket_path});
    my $cookie_path = File::Spec->catfile(
        dirname($socket),
        'config',
        'pulse',
        'cookie',
    );
    my $sink = _sink_name($args{sink_name});
    my $rate = _sample_rate($args{sample_rate});
    my $channels = _channels($args{channels});
    my $latency = exists $args{latency_ms}
        ? _integer($args{latency_ms}, 'latency_ms')
        : DEFAULT_LATENCY_MS;
    croak 'PulseAudio latency_ms must be between 20 and 2000'
        if $latency < 20 || $latency > 2_000;

    return {
        argv => [
            $binary,
            '--record',
            '--server', "unix:$socket",
            '--device', "$sink.monitor",
            '--format', 's16le',
            '--rate', $rate,
            '--channels', $channels,
            '--latency-msec', $latency,
            '--raw',
            '--client-name', 'SpotOn-Soloist-Capture',
            '--stream-name', 'SpotOn Soloist PCM',
        ],
        env => {
            PULSE_SERVER => "unix:$socket",
            PULSE_COOKIE => $cookie_path,
        },
        format      => 's16le',
        sample_rate => $rate,
        channels    => $channels,
        monitor     => "$sink.monitor",
    };
}

sub build_encoder_spec {
    my (%args) = @_;
    _reject_unknown(\%args, qw(binary channels sample_rate));

    my $binary = _required_text($args{binary}, 'encoder binary');
    my $rate = _sample_rate($args{sample_rate});
    my $channels = _channels($args{channels});

    return {
        argv => [
            $binary,
            '-nostdin',
            '-hide_banner',
            '-loglevel', 'warning',
            '-f', 's16le',
            '-ar', $rate,
            '-ac', $channels,
            '-i', 'pipe:0',
            '-map_metadata', '-1',
            '-vn',
            '-c:a', 'flac',
            '-f', 'flac',
            'pipe:1',
        ],
        input_format  => 's16le',
        output_format => 'flac',
        sample_rate   => $rate,
        channels      => $channels,
    };
}

sub _reject_unknown {
    my ($args, @supported) = @_;
    my %supported = map { $_ => 1 } @supported;
    for my $key (keys %$args) {
        croak "Unsupported Pulse bridge option: $key" unless $supported{$key};
    }
}

sub _required_text {
    my ($value, $name) = @_;
    croak "PulseAudio $name is required"
        unless defined $value && !ref($value) && length($value);
    croak "PulseAudio $name contains a control character"
        if $value =~ /[\x00-\x1f\x7f]/;
    return $value;
}

sub _socket_path {
    my ($value) = @_;
    $value = _required_text($value, 'socket_path');
    croak 'PulseAudio socket_path must be absolute'
        unless File::Spec->file_name_is_absolute($value);
    # PulseAudio parses module arguments after argv parsing.  Restrict the
    # interpolated value so whitespace or quoting cannot inject another module
    # argument even though no shell is involved.
    croak 'PulseAudio socket_path contains unsupported characters'
        unless $value =~ m{\A/[A-Za-z0-9._/-]+\z};
    return $value;
}

sub _sink_name {
    my ($value) = @_;
    $value = defined $value ? $value : 'spoton_soloist';
    croak 'PulseAudio sink_name must use letters, digits, dot, underscore, or dash'
        unless !ref($value) && $value =~ /\A[A-Za-z0-9_.-]+\z/;
    return $value;
}

sub _sample_rate {
    my ($value) = @_;
    $value = DEFAULT_SAMPLE_RATE unless defined $value;
    $value = _integer($value, 'sample_rate');
    croak 'PulseAudio sample_rate must be between 8000 and 192000'
        if $value < 8_000 || $value > 192_000;
    return $value;
}

sub _channels {
    my ($value) = @_;
    $value = DEFAULT_CHANNELS unless defined $value;
    $value = _integer($value, 'channels');
    croak 'PulseAudio channels must be between 1 and 8'
        if $value < 1 || $value > 8;
    return $value;
}

sub _integer {
    my ($value, $name) = @_;
    croak "PulseAudio $name must be an integer"
        unless defined $value && !ref($value) && $value =~ /\A\d+\z/;
    return 0 + $value;
}

1;

package Plugins::SpotOn::Soloist::ProcessSpec;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);

our @EXPORT_OK = qw(build_process_spec);

my %SUPPORTED_OPTIONS = map { $_ => 1 } qw(
    api_key
    binary
    cache_dir
    cache_size
    data_dir
    device_name
    initial_volume
    pipewire_device
    pulse_cookie
    pulse_latency_ms
    pulse_server
    verbose
);

use constant DEFAULT_PULSE_LATENCY_MS => 100;

# Build the Soloist daemon invocation as an argv array.  There is deliberately
# no shell-form command string: device names and paths must remain data, never
# executable syntax.  The WebSocket listener is also deliberately fixed to an
# automatically allocated loopback port because Soloist's local API has no
# authentication or TLS.
sub build_process_spec {
    my (%args) = @_;

    for my $key (keys %args) {
        croak "Unsupported Soloist process option: $key"
            unless $SUPPORTED_OPTIONS{$key};
    }

    my $binary     = _required_text($args{binary},     'binary');
    my $device     = _required_text($args{device_name}, 'device_name');
    my $api_key    = _required_text($args{api_key},    'api_key');
    my $data_dir   = _required_text($args{data_dir},   'data_dir');
    my $cache_dir  = _required_text($args{cache_dir},  'cache_dir');

    my $has_pulse_server = exists $args{pulse_server};
    my $has_pulse_cookie = exists $args{pulse_cookie};
    croak 'Soloist pulse_server and pulse_cookie must be provided together'
        if $has_pulse_server != $has_pulse_cookie;
    croak 'Soloist pulse_latency_ms requires pulse_server and pulse_cookie'
        if exists $args{pulse_latency_ms} && !$has_pulse_server;

    my %env;
    if ($has_pulse_server) {
        my $latency = exists $args{pulse_latency_ms}
            ? _integer($args{pulse_latency_ms}, 'pulse_latency_ms')
            : DEFAULT_PULSE_LATENCY_MS;
        croak 'Soloist pulse_latency_ms must be between 20 and 2000'
            if $latency < 20 || $latency > 2_000;

        $env{PULSE_SERVER} = _pulse_server($args{pulse_server});
        $env{PULSE_COOKIE} = _absolute_path(
            $args{pulse_cookie},
            'pulse_cookie',
        );
        # libpulse applies this in pa_stream's buffer-attribute patching.  It
        # keeps Soloist's playback queue aligned with our 100 ms monitor
        # capture instead of accepting the observed one-second default.
        $env{PULSE_LATENCY_MSEC} = "$latency";
    }

    my @argv = (
        $binary,
        '--device-name', $device,
        '--api-key',     $api_key,
        '--data-dir',    $data_dir,
        '--cache-dir',   $cache_dir,
        '--ws',          '127.0.0.1:0',
    );

    if (exists $args{cache_size}) {
        my $size = _integer($args{cache_size}, 'cache_size');
        croak 'Soloist cache_size must be 0 or at least 100'
            unless $size == 0 || $size >= 100;
        push @argv, '--cache-size', $size;
    }

    if (exists $args{initial_volume}) {
        my $volume = _integer($args{initial_volume}, 'initial_volume');
        croak 'Soloist initial_volume must be between 0 and 100'
            if $volume < 0 || $volume > 100;
        push @argv, '--initial-volume', $volume;
    }

    if (exists $args{pipewire_device}) {
        push @argv, '--pipewire-device',
            _required_text($args{pipewire_device}, 'pipewire_device');
    }

    push @argv, '--verbose' if _boolean($args{verbose}, 'verbose', 0);

    my @redacted = @argv;
    for my $index (0 .. $#redacted - 1) {
        if ($redacted[$index] eq '--api-key') {
            $redacted[$index + 1] = '[REDACTED]';
            last;
        }
    }

    return {
        argv           => \@argv,
        redacted_argv  => \@redacted,
        env            => \%env,
        websocket_bind => '127.0.0.1:0',
        data_dir       => $data_dir,
        cache_dir      => $cache_dir,
    };
}

sub _required_text {
    my ($value, $name) = @_;
    croak "Soloist $name is required"
        unless defined $value && !ref($value) && length($value);
    croak "Soloist $name contains a control character"
        if $value =~ /[\x00-\x1f\x7f]/;
    return $value;
}

sub _integer {
    my ($value, $name) = @_;
    croak "Soloist $name must be an integer"
        unless defined $value && !ref($value) && $value =~ /\A-?\d+\z/;
    return 0 + $value;
}

sub _pulse_server {
    my ($value) = @_;
    $value = _required_text($value, 'pulse_server');
    croak 'Soloist pulse_server must be an absolute Unix socket address'
        unless $value =~ /\Aunix:\/[A-Za-z0-9._\/-]+\z/;
    return $value;
}

sub _absolute_path {
    my ($value, $name) = @_;
    $value = _required_text($value, $name);
    croak "Soloist $name must be an absolute path"
        unless $value =~ /\A\/[A-Za-z0-9._\/-]+\z/;
    return $value;
}

sub _boolean {
    my ($value, $name, $default) = @_;
    return $default unless defined $value;
    croak "Soloist $name must be 0 or 1"
        unless !ref($value) && ($value eq '0' || $value eq '1');
    return $value ? 1 : 0;
}

1;

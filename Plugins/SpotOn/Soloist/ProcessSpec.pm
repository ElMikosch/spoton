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
    verbose
);

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

sub _boolean {
    my ($value, $name, $default) = @_;
    return $default unless defined $value;
    croak "Soloist $name must be 0 or 1"
        unless !ref($value) && ($value eq '0' || $value eq '1');
    return $value ? 1 : 0;
}

1;

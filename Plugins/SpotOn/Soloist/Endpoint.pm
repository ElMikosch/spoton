package Plugins::SpotOn::Soloist::Endpoint;

use strict;
use warnings;

use Exporter qw(import);
use File::Spec::Functions qw(catfile);

our @EXPORT_OK = qw(discover_endpoint is_loopback_address);

use constant MAX_RUNTIME_FILE_BYTES => 256;

# Discover the local WebSocket endpoint written by Soloist. The second return
# value is a stable error code; missing files are expected while the daemon is
# starting and therefore reported as "not_ready" rather than as an exception.
sub discover_endpoint {
    my ($data_dir) = @_;

    return (undef, 'data_dir_required')
        unless defined $data_dir && !ref($data_dir) && length($data_dir);
    return (undef, 'data_dir_missing')
        unless -d $data_dir;

    my ($address, $address_error) = _read_runtime_file(catfile($data_dir, 'ws.addr'));
    return (undef, $address_error) if $address_error;

    my ($port, $port_error) = _read_runtime_file(catfile($data_dir, 'ws.port'));
    return (undef, $port_error) if $port_error;

    return (undef, 'unsafe_address') unless is_loopback_address($address);
    return (undef, 'invalid_port')
        unless $port =~ m{\A\d+\z} && $port >= 1 && $port <= 65_535;

    my $normalized_address = $address;
    $normalized_address = '127.0.0.1' if lc($normalized_address) eq 'localhost';
    $normalized_address =~ s{\A\[(.+)\]\z}{$1};

    my $url_address = $normalized_address =~ /:/
        ? "[$normalized_address]"
        : $normalized_address;

    my $pid;
    my ($pid_text, $pid_error) = _read_runtime_file(
        catfile($data_dir, 'soloist.pid'),
        optional => 1,
    );
    if (!$pid_error && defined $pid_text && $pid_text =~ m{\A\d+\z} && $pid_text > 0) {
        $pid = 0 + $pid_text;
    }

    return ({
        address  => $normalized_address,
        port     => 0 + $port,
        url      => "ws://$url_address:" . (0 + $port),
        pid      => $pid,
        data_dir => $data_dir,
    }, undef);
}

sub is_loopback_address {
    my ($address) = @_;
    return 0 unless defined $address && !ref($address) && length($address);

    return 1 if lc($address) eq 'localhost';
    return 1 if $address eq '::1' || $address eq '[::1]';

    return 0 unless $address =~ m{\A127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z};
    return $1 <= 255 && $2 <= 255 && $3 <= 255 ? 1 : 0;
}

sub _read_runtime_file {
    my ($path, %args) = @_;

    return (undef, undef) if $args{optional} && !-e $path;
    return (undef, 'not_ready') unless -f $path;

    open(my $fh, '<', $path) or return (undef, 'read_failed');
    binmode($fh);

    my $buffer = '';
    my $bytes = read($fh, $buffer, MAX_RUNTIME_FILE_BYTES + 1);
    close($fh);

    return (undef, 'read_failed') unless defined $bytes;
    return (undef, 'invalid_runtime_file') if $bytes > MAX_RUNTIME_FILE_BYTES;

    $buffer =~ s{\A\s+}{};
    $buffer =~ s{\s+\z}{};
    return (undef, 'not_ready') unless length($buffer);

    return ($buffer, undef);
}

1;

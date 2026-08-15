#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Endpoint qw(discover_endpoint is_loopback_address);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $content;
    close($fh);
}

my ($endpoint, $error) = discover_endpoint(undef);
ok(!$endpoint, 'missing data directory has no endpoint');
is($error, 'data_dir_required', 'missing data directory has stable error code');

my $missing_dir = tempdir(CLEANUP => 1) . '/missing';
($endpoint, $error) = discover_endpoint($missing_dir);
ok(!$endpoint, 'non-existent data directory has no endpoint');
is($error, 'data_dir_missing', 'non-existent data directory is distinguished');

my $data_dir = tempdir(CLEANUP => 1);
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'empty data directory is not ready');
is($error, 'not_ready', 'missing runtime files are a normal startup state');

write_file(catfile($data_dir, 'ws.addr'), "127.0.0.1\n");
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'address without port is not ready');
is($error, 'not_ready', 'partial endpoint stays in startup state');

write_file(catfile($data_dir, 'ws.port'), " 19090 \n");
write_file(catfile($data_dir, 'soloist.pid'), "4242\n");
($endpoint, $error) = discover_endpoint($data_dir);
is($error, undef, 'valid endpoint has no error');
is($endpoint->{address}, '127.0.0.1', 'IPv4 loopback address is retained');
is($endpoint->{port}, 19_090, 'port is numeric');
is($endpoint->{url}, 'ws://127.0.0.1:19090', 'IPv4 WebSocket URL is built');
is($endpoint->{pid}, 4242, 'optional daemon PID is discovered');
is($endpoint->{data_dir}, $data_dir, 'endpoint retains its data directory');

write_file(catfile($data_dir, 'ws.addr'), "localhost\n");
($endpoint, $error) = discover_endpoint($data_dir);
is($endpoint->{address}, '127.0.0.1', 'localhost is normalized without DNS lookup');
is($endpoint->{url}, 'ws://127.0.0.1:19090', 'normalized localhost URL is loopback-only');

write_file(catfile($data_dir, 'ws.addr'), "::1\n");
($endpoint, $error) = discover_endpoint($data_dir);
is($endpoint->{address}, '::1', 'IPv6 loopback address is retained');
is($endpoint->{url}, 'ws://[::1]:19090', 'IPv6 WebSocket URL uses brackets');

write_file(catfile($data_dir, 'ws.addr'), "0.0.0.0\n");
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'wildcard bind address is rejected');
is($error, 'unsafe_address', 'wildcard address has security error code');

write_file(catfile($data_dir, 'ws.addr'), "192.168.1.20\n");
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'LAN address is rejected');
is($error, 'unsafe_address', 'LAN address cannot expose unauthenticated API');

write_file(catfile($data_dir, 'ws.addr'), "127.0.0.1\n");
write_file(catfile($data_dir, 'ws.port'), "0\n");
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'port zero is rejected after startup');
is($error, 'invalid_port', 'port zero has stable error code');

write_file(catfile($data_dir, 'ws.port'), "65536\n");
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'port above TCP range is rejected');
is($error, 'invalid_port', 'oversized port has stable error code');

write_file(catfile($data_dir, 'ws.port'), "abc\n");
($endpoint, $error) = discover_endpoint($data_dir);
ok(!$endpoint, 'non-numeric port is rejected');
is($error, 'invalid_port', 'non-numeric port has stable error code');

write_file(catfile($data_dir, 'ws.port'), "19090\n");
write_file(catfile($data_dir, 'soloist.pid'), "not-a-pid\n");
($endpoint, $error) = discover_endpoint($data_dir);
is($endpoint->{pid}, undef, 'malformed optional PID does not hide valid endpoint');

ok(is_loopback_address('127.255.1.2'), '127/8 address is loopback');
ok(!is_loopback_address('127.999.1.2'), 'invalid 127/8 address is rejected');
ok(is_loopback_address('[::1]'), 'bracketed IPv6 loopback is accepted');
ok(!is_loopback_address('example.com'), 'hostname other than localhost is rejected');

done_testing();

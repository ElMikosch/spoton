#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Transport;

{
    package Local::FakeWS;

    sub new {
        my ($class) = @_;
        return bless {
            sent       => [],
            listening  => 0,
            closed     => 0,
            ended      => 0,
            read_cb    => undef,
            failed_cb  => undef,
        }, $class;
    }

    sub listenAsync {
        my ($self, $read_cb, $failed_cb) = @_;
        $self->{listening} = 1;
        $self->{read_cb} = $read_cb;
        $self->{failed_cb} = $failed_cb;
    }

    sub send {
        my ($self, $frame) = @_;
        push @{ $self->{sent} }, $frame;
    }

    sub emit {
        my ($self, $frame) = @_;
        $self->{read_cb}->($frame);
    }

    sub fail_read {
        my ($self, $message) = @_;
        $self->{failed_cb}->($message);
    }

    sub endListenAsync { $_[0]{ended} = 1 }
    sub close          { $_[0]{closed} = 1 }
}

my @connected;
my @disconnected;
my @events;
my @errors;
my @factory_urls;
my $socket;

my $transport = Plugins::SpotOn::Soloist::Transport->new(
    ws_factory => sub {
        my ($url, $connected_cb) = @_;
        push @factory_urls, $url;
        $socket = Local::FakeWS->new();
        $connected_cb->();
        return $socket;
    },
    on_connected => sub { push @connected, [@_] },
    on_disconnected => sub { push @disconnected, [@_] },
    on_event => sub { push @events, [@_] },
    on_error => sub { push @errors, [@_] },
);

ok($transport->connect('ws://127.0.0.1:19090'), 'transport starts loopback connection');
is($transport->state, 'connected', 'synchronous handshake reaches connected state');
ok($transport->connected, 'connected accessor is true');
is($transport->url, 'ws://127.0.0.1:19090', 'transport retains endpoint URL');
is_deeply(\@factory_urls, ['ws://127.0.0.1:19090'], 'factory receives endpoint');
ok($socket->{listening}, 'transport starts asynchronous listener');
is(scalar @connected, 1, 'connected callback fires once');

ok(
    $transport->send_action('play', uri => 'spotify:album:album1'),
    'play action is sent',
);
is(scalar @{ $socket->{sent} }, 1, 'play produces one WebSocket frame');
is_deeply(
    JSON::PP::decode_json($socket->{sent}[0]),
    {
        type    => 'command',
        command => 'play',
        uri     => 'spotify:album:album1',
    },
    'sent play frame uses Soloist wire shape',
);

ok($transport->send_action('repeat', mode => 'track'), 'track repeat action is sent');
is(scalar @{ $socket->{sent} }, 3, 'repeat produces two additional frames');
is(
    JSON::PP::decode_json($socket->{sent}[1])->{command},
    'set_repeat_context',
    'repeat first disables context mode',
);
is(
    JSON::PP::decode_json($socket->{sent}[2])->{command},
    'set_repeat_track',
    'repeat then enables track mode',
);

$socket->emit('{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"LMS"}');
is(scalar @events, 1, 'valid JSON event reaches callback');
is($events[0][0]{kind}, 'auth', 'incoming event is normalized');
is($events[0][0]{logged_in}, 1, 'normalized auth state retains login flag');
is($events[0][1]{type}, 'auth_state', 'raw decoded event is available to adapter');

$socket->emit('{broken json');
is($errors[-1][0], 'invalid_json', 'invalid JSON reports stable transport error');
is($transport->state, 'connected', 'invalid event does not tear down connection');

ok(
    !$transport->send_action('volume', volume => 101),
    'invalid command is not sent',
);
is($errors[-1][0], 'invalid_command', 'command validation failure reaches error callback');
is(scalar @{ $socket->{sent} }, 3, 'invalid command emits no frame');

$socket->fail_read('remote closed');
is($transport->state, 'disconnected', 'read failure marks transport disconnected');
is(scalar @disconnected, 1, 'disconnected callback fires');
is($disconnected[0][0], 'remote closed', 'disconnect reason is retained');
ok($socket->{closed}, 'failed socket is closed');

ok(!$transport->send_action('pause'), 'command while disconnected is rejected');
is($errors[-1][0], 'not_connected', 'disconnected send has stable error code');

my $factory_called = 0;
my $unsafe = Plugins::SpotOn::Soloist::Transport->new(
    ws_factory => sub { $factory_called++; return Local::FakeWS->new() },
    on_error => sub { push @errors, [@_] },
);
ok(!$unsafe->connect('ws://192.168.1.10:9090'), 'non-loopback endpoint is rejected');
is($factory_called, 0, 'unsafe endpoint never reaches socket factory');
is($unsafe->last_error->{code}, 'unsafe_endpoint', 'unsafe endpoint error is inspectable');
ok(!$unsafe->connect('ws://127.999.1.1:9090'), 'invalid loopback-looking address is rejected');
ok(!$unsafe->connect('ws://127.0.0.1:0'), 'invalid loopback port is rejected');

my ($late_connected_cb, $async_socket);
my $async = Plugins::SpotOn::Soloist::Transport->new(
    ws_factory => sub {
        my (undef, $connected_cb) = @_;
        $late_connected_cb = $connected_cb;
        $async_socket = Local::FakeWS->new();
        return $async_socket;
    },
);
ok($async->connect('ws://[::1]:9999'), 'asynchronous factory starts connection');
is($async->state, 'connecting', 'transport waits for asynchronous handshake');
ok(!$async_socket->{listening}, 'listener waits for handshake completion');
$late_connected_cb->();
is($async->state, 'connected', 'late handshake completes connection');
ok($async_socket->{listening}, 'late handshake starts listener');
$async->close();
is($async->state, 'closed', 'explicit close sets closed state');
ok($async_socket->{ended}, 'explicit close ends async listener');
ok($async_socket->{closed}, 'explicit close closes socket');

my $connect_failure = Plugins::SpotOn::Soloist::Transport->new(
    ws_factory => sub {
        my (undef, undef, $failed_cb) = @_;
        $failed_cb->('connection refused');
        return Local::FakeWS->new();
    },
    on_error => sub { push @errors, [@_] },
);
ok(!$connect_failure->connect('ws://127.0.0.1:1'), 'connection callback failure is returned');
is($connect_failure->state, 'error', 'connection failure sets error state');
is($connect_failure->last_error->{message}, 'connection refused', 'connection error is retained');

done_testing();

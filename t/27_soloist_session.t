#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Session;

{
    package Local::FakeTransport;

    sub new {
        return bless {
            callbacks => {},
            actions   => [],
            connected => 0,
            closed    => 0,
            url       => undef,
        }, shift;
    }

    sub set_callbacks {
        my ($self, %callbacks) = @_;
        $self->{callbacks} = { %callbacks };
        return $self;
    }

    sub connect {
        my ($self, $url) = @_;
        $self->{url} = $url;
        $self->{connected} = 1;
        $self->{callbacks}{on_connected}->($url);
        return 1;
    }

    sub connected { $_[0]{connected} }

    sub send_action {
        my ($self, $action, %args) = @_;
        push @{ $self->{actions} }, [$action, { %args }];
        return 1;
    }

    sub emit {
        my ($self, $event) = @_;
        $self->{callbacks}{on_event}->($event, {});
    }

    sub disconnect {
        my ($self, $message) = @_;
        $self->{connected} = 0;
        $self->{callbacks}{on_disconnected}->($message);
    }

    sub fail {
        my ($self, $code, $message) = @_;
        $self->{callbacks}{on_error}->($code, $message);
    }

    sub close {
        my ($self) = @_;
        $self->{connected} = 0;
        $self->{closed} = 1;
        return 1;
    }
}

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $content;
    close($fh);
}

my @errors;
my $empty_dir = tempdir(CLEANUP => 1);
my $waiting = Plugins::SpotOn::Soloist::Session->new(
    data_dir => $empty_dir,
    on_error => sub { push @errors, [@_] },
);
ok(!$waiting->start(), 'session waits when Soloist runtime files are absent');
is($waiting->status, 'waiting_endpoint', 'missing endpoint has waiting status');
is(scalar @errors, 0, 'normal daemon startup wait is not reported as error');

my $data_dir = tempdir(CLEANUP => 1);
write_file(catfile($data_dir, 'ws.addr'), "127.0.0.1\n");
write_file(catfile($data_dir, 'ws.port'), "19090\n");
write_file(catfile($data_dir, 'soloist.pid'), "1234\n");

my @statuses;
my @updates;
my $transport = Local::FakeTransport->new();
my $session = Plugins::SpotOn::Soloist::Session->new(
    data_dir  => $data_dir,
    transport => $transport,
    on_status => sub { push @statuses, [@_] },
    on_update => sub { push @updates, [@_] },
    on_error  => sub { push @errors, [@_] },
);

ok($session->start(), 'session connects to discovered endpoint');
ok($session->connected, 'session reports connected transport');
is($session->status, 'connected', 'session status reaches connected');
is($transport->{url}, 'ws://127.0.0.1:19090', 'session passes discovered URL to transport');
is_deeply(
    $transport->{actions}[0],
    ['auth_state', {}],
    'session requests deterministic auth snapshot on connect',
);
is($session->endpoint->{pid}, 1234, 'session exposes discovered daemon PID');
is_deeply(
    [map { $_->[0] } @statuses],
    [qw(connecting connected)],
    'status callback observes connection lifecycle',
);

$transport->emit({
    kind        => 'auth',
    event_type  => 'auth_state',
    logged_in   => 1,
    is_active   => 1,
    device_name => 'Living room',
});
my $snapshot = $session->snapshot();
is($snapshot->{auth}{logged_in}, 1, 'auth event updates session snapshot');
is($snapshot->{auth}{device_name}, 'Living room', 'auth snapshot retains device name');

$transport->emit({
    kind       => 'state',
    event_type => 'playback_state',
    status     => 'playing',
    item       => { uri => 'spotify:track:one', name => 'One' },
    context    => { uri => 'spotify:album:album' },
    position   => { position_ms => 1000, timestamp_ms => 2000, speed => 1 },
    volume     => 55,
    is_active  => 1,
    options    => { shuffle => 0, repeat => 'off' },
    available_actions => { pause => {} },
});
$snapshot = $session->snapshot();
is($snapshot->{playback}{status}, 'playing', 'full playback event sets status');
is($snapshot->{playback}{item}{name}, 'One', 'full playback event sets item');
is($snapshot->{playback}{volume}, 55, 'full playback event sets volume');
is($snapshot->{playback}{position}{position_ms}, 1000, 'full event sets position anchor');

$transport->emit({
    kind       => 'item',
    event_type => 'track_changed',
    item       => { uri => 'spotify:track:two', name => 'Two' },
});
$transport->emit({ kind => 'playback', event_type => 'playback_changed', status => 'paused' });
$transport->emit({ kind => 'volume', event_type => 'volume_changed', volume => 42 });
$transport->emit({
    kind       => 'position',
    event_type => 'position_sync',
    position   => { position_ms => 3000, timestamp_ms => 4000, speed => 0 },
});
$snapshot = $session->snapshot();
is($snapshot->{playback}{item}{name}, 'Two', 'granular item event updates snapshot');
is($snapshot->{playback}{status}, 'paused', 'granular playback event updates snapshot');
is($snapshot->{playback}{volume}, 42, 'granular volume event updates snapshot');
is($snapshot->{playback}{position}{speed}, 0, 'granular position event updates snapshot');

$transport->emit({
    kind       => 'queue',
    event_type => 'queue_changed',
    previous   => [],
    upcoming   => [{ uid => 'q1', item => { uri => 'spotify:track:three' } }],
});
is(
    $session->snapshot->{queue}{upcoming}[0]{item}{uri},
    'spotify:track:three',
    'queue event updates upcoming items',
);

my $update_snapshot = $updates[-1][1];
$update_snapshot->{queue}{upcoming}[0]{item}{uri} = 'mutated';
is(
    $session->snapshot->{queue}{upcoming}[0]{item}{uri},
    'spotify:track:three',
    'callback receives a defensive state copy',
);

ok($session->send_action('pause'), 'session delegates playback command');
is($transport->{actions}[-1][0], 'pause', 'delegated action name is retained');

$transport->fail('invalid_json', 'bad frame');
is($session->snapshot->{last_error}{code}, 'invalid_json', 'transport error is retained');
is($session->status, 'connected', 'recoverable frame error keeps session connected');

$transport->disconnect('daemon stopped');
is($session->status, 'disconnected', 'transport disconnect updates session status');
is($session->snapshot->{last_error}{message}, 'daemon stopped', 'disconnect reason is retained');

ok($session->stop(), 'session stops cleanly');
is($session->status, 'stopped', 'stop updates session status');
ok($transport->{closed}, 'stop closes transport');

done_testing();

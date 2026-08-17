#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

BEGIN {
    package main;
    sub INFOLOG () { 0 }
    our $SCANNER = 0;

    package Slim::Utils::Log;
    sub import { }
    sub logger { bless {}, 'Local::Log' }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package Local::Log;
    sub warn { }
    sub info { }
    sub is_info { 0 }

    package Slim::Utils::Prefs;
    our %values;
    sub import { }
    sub preferences { bless { namespace => $_[0] }, 'Local::Prefs' }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package Local::Prefs;
    sub get { $Slim::Utils::Prefs::values{ $_[0]{namespace} }{ $_[1] } }
    sub set { $Slim::Utils::Prefs::values{ $_[0]{namespace} }{ $_[1] } = $_[2] }

    package Slim::Utils::Timers;
    our @set;
    our @killed;
    sub setTimer { push @set, [@_] }
    sub killTimers { push @killed, [@_] }
    $INC{'Slim/Utils/Timers.pm'} = 1;

    package Slim::Utils::Network;
    sub serverAddr { '192.0.2.10' }
    $INC{'Slim/Utils/Network.pm'} = 1;

    package Slim::Player::Client;
    our @clients;
    sub clients { @clients }
    sub getClient {
        my ($id) = @_;
        ($id) = @_ > 1 ? $_[1] : $_[0];
        for my $client (@clients) {
            return $client if $client->id eq $id;
        }
        return;
    }
    $INC{'Slim/Player/Client.pm'} = 1;

    package Slim::Player::Sync;
    sub slaves {
        my ($master) = @_;
        return grep {
            $_->id ne $master->id && $_->master->id eq $master->id
        } @Slim::Player::Client::clients;
    }
    $INC{'Slim/Player/Sync.pm'} = 1;

    package Slim::Music::Info;
    our @titles;
    sub setCurrentTitle { push @titles, [@_] }
    $INC{'Slim/Music/Info.pm'} = 1;

    package Slim::Control::Request;
    our @requests;
    our @notifications;
    our @subscriptions;
    sub new {
        my ($class, $client_id, $command) = @_;
        my $self = bless {
            client_id => $client_id,
            command   => [@$command],
            executed  => 0,
        }, $class;
        push @requests, $self;
        return $self;
    }
    sub source { $_[0]{source} = $_[1] if @_ > 1; $_[0]{source} }
    sub execute {
        my ($self) = @_;
        $self->{executed} = 1;
        my $client = Slim::Player::Client::getClient($self->{client_id});
        if ($client && $self->{command}[0] eq 'playlist'
            && $self->{command}[1] eq 'play') {
            $client->{song} = Local::Song->new($self->{command}[2]);
            $client->{playing} = 1;
        }
        elsif ($client && $self->{command}[0] eq 'pause') {
            $client->{playing} = $self->{command}[1] ? 0 : 1;
        }
        elsif ($client && $self->{command}[0] eq 'stop') {
            $client->{playing} = 0;
            $client->{song} = undef;
        }
        return 1;
    }
    sub notifyFromArray { push @notifications, [@_] }
    sub subscribe { push @subscriptions, [@_] }
    sub unsubscribe { 1 }
    $INC{'Slim/Control/Request.pm'} = 1;
}

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Manager;
use Plugins::SpotOn::Soloist::PlayerRuntime;
use Plugins::SpotOn::Soloist::AudioPreflight;
use Plugins::SpotOn::Soloist::Transport;
use Plugins::SpotOn::Soloist::Runtime;
use Plugins::SpotOn::Soloist::Session;
use Plugins::SpotOn::Soloist::StreamServer;

{
    package Local::Track;
    sub new { bless { url => $_[1] }, $_[0] }
    sub url { $_[0]{url} }

    package Local::Song;
    sub new {
        bless {
            stream_url => $_[1],
            track      => Local::Track->new($_[1]),
            plugin     => {},
            duration   => 0,
            offset     => 0,
        }, $_[0];
    }
    sub track { $_[0]{track} }
    sub streamUrl { $_[0]{stream_url} }
    sub pluginData {
        my ($self, $key, $value) = @_;
        $self->{plugin}{$key} = $value if @_ > 2;
        return $self->{plugin}{$key};
    }
    sub duration { $_[0]{duration} = $_[1] if @_ > 1; $_[0]{duration} }
    sub startOffset { $_[0]{offset} = $_[1] if @_ > 1; $_[0]{offset} }

    package Local::Player;
    sub new {
        my ($class, $id, $name) = @_;
        my $self = bless {
            id      => $id,
            name    => $name,
            playing => 0,
            synced  => 0,
        }, $class;
        $self->{master} = $self;
        return $self;
    }
    sub id { $_[0]{id} }
    sub name { $_[0]{name} }
    sub master { $_[0]{master} }
    sub isSynced { $_[0]{synced} }
    sub model { 'squeezebox' }
    sub isPlaying { $_[0]{playing} }
    sub playingSong { $_[0]{song} }
    sub songElapsedSeconds { $_[0]{elapsed} || 0 }
    sub playPoint { $_[0]{play_point} = $_[1] if @_ > 1; $_[0]{play_point} }
    sub streamingProgressBar { $_[0]{progress_bar} = $_[1] }
    sub currentPlaylistUpdateTime { $_[0]{updated} = $_[1] }

    package Local::Runtime;
    our @instances;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            args    => { %args },
            state   => 'stopped',
            stopped => 0,
        }, 'Local::Runtime';
        push @instances, $self;
        return $self;
    }
    sub start { $_[0]{state} = 'starting_pulse'; 1 }
    sub poll { $_[0]{state} = 'running'; 'running' }
    sub state { $_[0]{state} }
    sub last_error { $_[0]{last_error} }
    sub stop { $_[0]{stopped}++; $_[0]{state} = 'stopped'; 1 }
    sub status_snapshot {
        { state => $_[0]{state}, soloistArgv => ['--api-key', '[REDACTED]'] }
    }
    sub new_stream_pipeline { bless {}, 'Local::Pipeline' }

    package Local::Session;
    our @instances;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            args      => { %args },
            status    => 'idle',
            connected => 0,
            snapshot  => {
                connection => 'idle',
                playback   => {},
                queue      => { previous => [], upcoming => [] },
            },
        }, 'Local::Session';
        push @instances, $self;
        return $self;
    }
    sub start { $_[0]{status} = 'connected'; $_[0]{connected} = 1; 1 }
    sub refresh { $_[0]{connected} = 1; 1 }
    sub connected { $_[0]{connected} }
    sub status { $_[0]{status} }
    sub snapshot { $_[0]{snapshot} }
    sub stop { $_[0]{connected} = 0; $_[0]{status} = 'stopped'; 1 }
    sub send_action { push @{ $_[0]{actions} }, [$_[1], { @_[2 .. $#_] }]; 1 }
    sub emit {
        my ($self, $event, $snapshot) = @_;
        $self->{snapshot} = $snapshot;
        $self->{args}{on_update}->($event, $snapshot);
    }

    package Local::Pipeline;
    sub start { 1 }
    sub stop { 1 }
}

my $root = tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::values{server}{cachedir} = $root;
$Slim::Utils::Prefs::values{server}{httpport} = 9000;
$Slim::Utils::Prefs::values{'plugin.spoton'}{diagnosticMode} = 1;
$Slim::Utils::Prefs::values{'plugin.spoton'}{soloistConfigured} = 1;

my $base = catdir($root, 'spoton', 'soloist-managed');
make_path($base, { mode => 0700 });
my $key_file = catfile($base, 'api-key');
open(my $key_fh, '>', $key_file) or die "Cannot create API key fixture: $!";
print {$key_fh} 'manager-secret-key';
close($key_fh);
chmod 0600, $key_file;

my $kitchen = Local::Player->new('00:11:22:33:44:55', 'Kitchen');
my $living  = Local::Player->new('00:11:22:33:44:66', 'Living room');
@Slim::Player::Client::clients = ($kitchen, $living);

my @registered;
my @unregistered;
my $token_index = 0;
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Transport::websocket_available = sub { 1 };
    local *Plugins::SpotOn::Soloist::AudioPreflight::inspect = sub {
        return { tools => {
            soloist    => '/usr/local/bin/soloist',
            pulseaudio => '/usr/bin/pulseaudio',
            parec      => '/usr/bin/parec',
            ffmpeg     => '/usr/bin/ffmpeg',
        } };
    };
    local *Plugins::SpotOn::Soloist::Runtime::new = \&Local::Runtime::new;
    local *Plugins::SpotOn::Soloist::Session::new = \&Local::Session::new;
    local *Plugins::SpotOn::Soloist::PlayerRuntime::_random_token = sub {
        return sprintf('%024x', ++$token_index);
    };
    local *Plugins::SpotOn::Soloist::Manager::_device_name_for_client = sub {
        my ($client) = @_;
        return $client->name . ($client->isSynced ? ' (Group)' : '');
    };
    local *Plugins::SpotOn::Soloist::StreamServer::init = sub { 1 };
    local *Plugins::SpotOn::Soloist::StreamServer::register_runtime = sub {
        my ($class, $token, $factory) = @_;
        push @registered, [$token, 'flac', $factory];
        return "/plugins/SpotOn/soloist/stream/$token.flac";
    };
    local *Plugins::SpotOn::Soloist::StreamServer::register_runtime_format = sub {
        my ($class, $token, $format, $factory) = @_;
        push @registered, [$token, $format, $factory];
        return "/plugins/SpotOn/soloist/stream/$token.soc";
    };
    local *Plugins::SpotOn::Soloist::StreamServer::unregister_runtime = sub {
        push @unregistered, $_[1];
        return 1;
    };

    ok(Plugins::SpotOn::Soloist::Manager->init(), 'manager initializes once');
    ok(Plugins::SpotOn::Soloist::Manager->start(), 'manager starts player discovery');

    # First player starts immediately; later players are staggered.
    Plugins::SpotOn::Soloist::Manager::_start_one_timer(
        'Plugins::SpotOn::Soloist::Manager', $living,
    );
    is(scalar @Local::Runtime::instances, 2, 'one Soloist runtime is created per LMS player');
    is($Local::Runtime::instances[0]{args}{device_name}, 'Kitchen', 'first device uses LMS player name');
    is($Local::Runtime::instances[1]{args}{device_name}, 'Living room', 'second device uses LMS player name');
    is($Local::Runtime::instances[0]{args}{initial_volume}, 100, 'capture stays full-scale');

    Plugins::SpotOn::Soloist::Manager::_poll();
    my $running = Plugins::SpotOn::Soloist::Manager->statusSnapshot();
    is($running->{state}, 'running', 'aggregate manager reaches running state');
    is($running->{playerCount}, 2, 'status exposes both player runtimes');
    is(scalar @registered, 4, 'both PCM and FLAC routes are registered per player');

    my $instance = Plugins::SpotOn::Soloist::Manager->instanceForClient($kitchen);
    ok($instance, 'runtime resolves by LMS player');
    my $token = $instance->stream_token;

    my $snapshot = {
        connection => 'connected',
        playback => {
            status    => 'playing',
            is_active => 1,
            volume    => 71,
            position  => { position_ms => 12_000, timestamp_ms => 0, speed => 1 },
            item      => {
                uri         => 'spotify:track:abc123',
                name        => 'Cosmic Love',
                duration_ms => 255_906,
                parent      => { name => 'Lungs' },
                creators    => [{ name => 'Florence + The Machine' }],
                covers      => [
                    { size => 'small',  url => 'https://example.test/small.jpg' },
                    { size => 'xlarge', url => 'https://example.test/large.jpg' },
                ],
            },
        },
    };
    $instance->{session}->emit(
        { kind => 'state', event_type => 'playback_state' },
        $snapshot,
    );
    is_deeply(
        $Slim::Control::Request::requests[-1]{command},
        [
            'playlist', 'play',
            "spoton://soloist-pcm:$token",
            'Florence + The Machine - Cosmic Love',
        ],
        'active Spotify device automatically attaches its matching LMS player',
    );
    is($kitchen->playingSong->pluginData('info')->{title}, 'Cosmic Love', 'title reaches LMS song metadata');
    is($kitchen->playingSong->pluginData('info')->{artist}, 'Florence + The Machine', 'artist reaches LMS song metadata');
    is($kitchen->playingSong->pluginData('info')->{album}, 'Lungs', 'album reaches LMS song metadata');
    is($kitchen->playingSong->pluginData('info')->{cover}, 'https://example.test/large.jpg', 'largest Soloist cover is selected');
    cmp_ok(abs($kitchen->playingSong->duration - 255.906), '<', 0.001, 'duration reaches LMS song object');
    like($Slim::Music::Info::titles[-1][1], qr/Florence.*Cosmic Love/, 'hardware title is updated immediately');
    ok(@Slim::Control::Request::notifications, 'newmetadata notification is emitted');
    is(
        Plugins::SpotOn::Soloist::Manager->metadataForToken($token)->{spotifyUri},
        'spotify:track:abc123',
        'protocol metadata resolves from the matching runtime token',
    );

    # Group while playback is active. The runtime and Spotify session survive;
    # only an idle future reconcile is allowed to apply the cosmetic suffix.
    $kitchen->{synced} = 1;
    $living->{synced} = 1;
    $living->{master} = $kitchen;
    Plugins::SpotOn::Soloist::Manager->reconcile();
    is(
        Plugins::SpotOn::Soloist::Manager->instanceForClient($kitchen),
        $instance,
        'active Soloist runtime survives solo-to-group topology transition',
    );
    is($instance->device_name, 'Kitchen', 'active device keeps its existing Spotify name');
    is($Local::Runtime::instances[0]{stopped}, 0, 'active runtime is not stopped during grouping');
    ok($Local::Runtime::instances[1]{stopped}, 'former slave device is removed when inactive');

    # Even when LMS elects the other box as sync master, the process which
    # owns the live Spotify session remains authoritative.  Do not create an
    # idle duplicate under the new master while playback is active.
    my $runtime_count = scalar @Local::Runtime::instances;
    $kitchen->{master} = $living;
    $living->{master} = $living;
    Plugins::SpotOn::Soloist::Manager->reconcile();
    is(
        Plugins::SpotOn::Soloist::Manager->instanceForClient($living),
        $instance,
        'active member runtime follows a sync-master change',
    );
    is(
        scalar @Local::Runtime::instances,
        $runtime_count,
        'sync-master change does not start a duplicate Soloist endpoint',
    );

    # Restore the original master for the remaining metadata/name assertions.
    $kitchen->{master} = $kitchen;
    $living->{master} = $kitchen;
    Plugins::SpotOn::Soloist::Manager->reconcile();

    # A track change updates metadata on the continuous stream without another
    # playlist play request.
    my $plays_before = scalar grep {
        $_->{command}[0] eq 'playlist' && $_->{command}[1] eq 'play'
    } @Slim::Control::Request::requests;
    $snapshot->{playback}{item}{uri} = 'spotify:track:def456';
    $snapshot->{playback}{item}{name} = 'Dog Days Are Over';
    $instance->{session}->emit(
        { kind => 'item', event_type => 'track_changed' },
        $snapshot,
    );
    is($kitchen->playingSong->pluginData('info')->{title}, 'Dog Days Are Over', 'track change refreshes metadata');
    my $plays_after = scalar grep {
        $_->{command}[0] eq 'playlist' && $_->{command}[1] eq 'play'
    } @Slim::Control::Request::requests;
    is($plays_after, $plays_before, 'track change does not reopen the audio stream');

    # Once inactive, reconciliation is free to replace the process with the
    # stable localized group name.
    $snapshot->{playback}{is_active} = 0;
    $instance->{session}{snapshot} = $snapshot;
    Plugins::SpotOn::Soloist::Manager->reconcile();
    my $group_instance = Plugins::SpotOn::Soloist::Manager->instanceForClient($kitchen);
    isnt($group_instance, $instance, 'idle name transition creates a fresh group runtime');
    is($group_instance->device_name, 'Kitchen (Group)', 'group runtime uses static suffix');

    ok(Plugins::SpotOn::Soloist::Manager->stop(), 'manager stops all runtimes');
    is(Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{state}, 'stopped', 'aggregate state stops cleanly');
}

unlink($key_file);
ok(!Plugins::SpotOn::Soloist::Manager->start(), 'missing API key still fails closed');
is(
    Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError}{code},
    'api_key_missing',
    'missing API key retains stable failure code',
);

done_testing();

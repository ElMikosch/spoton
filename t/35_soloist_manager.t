#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Digest::MD5 ();
use JSON::PP ();
use File::Spec ();

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
            $client->{paused} = 0;
        }
        elsif ($client && $self->{command}[0] eq 'pause') {
            $client->{playing} = $self->{command}[1] ? 0 : 1;
            $client->{paused} = $self->{command}[1] ? 1 : 0;
        }
        elsif ($client && $self->{command}[0] eq 'stop') {
            $client->{playing} = 0;
            $client->{paused} = 0;
            $client->{song} = undef;
        }
        return 1;
    }
    sub notifyFromArray { push @notifications, [@_] }

    # Minimal notification request as delivered to subscribers.
    sub notification {
        my ($class, $client, @command) = @_;
        return bless { client => $client, command => [@command] }, 'Local::Notification';
    }

    package Local::Notification;
    sub client { $_[0]{client} }
    sub source { undef }
    sub getParam {
        my ($self, $name) = @_;
        return $self->{command}[2] if $name eq '_newvalue' || $name eq '_index';
        return;
    }
    sub isCommand {
        my ($self, $spec) = @_;
        my ($first, $second) = map { { map { $_ => 1 } @$_ } } @$spec;
        return $first->{ $self->{command}[0] }
            && (!$second || $second->{ $self->{command}[1] }) ? 1 : 0;
    }
    sub isNotCommand { !$_[0]->isCommand($_[1]) }

    package Slim::Control::Request;
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
    sub isPaused { $_[0]{paused} }
    sub isStopped { !$_[0]{playing} && !$_[0]{paused} }
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
    sub poll {
        my ($self) = @_;
        if ($self->{fail_with}) {
            $self->{state} = 'failed';
            $self->{last_error} = { code => $self->{fail_with}, message => 'fixture failure' };
            return 'failed';
        }
        $self->{state} = 'running';
        return 'running';
    }
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

    # ---- Runtime layout: the Pulse socket path must fit sun_path. ----
    my $long_cache = catdir($root, 'x' x 40);
    $Slim::Utils::Prefs::values{server}{cachedir} = '/var/lib/squeezeboxserver/cache';
    my $hash = Digest::MD5::md5_hex('00:11:22:33:44:55');
    my $packaged = Plugins::SpotOn::Soloist::Manager::_runtime_dir_for($hash);
    is(
        $packaged,
        '/var/lib/squeezeboxserver/cache/spoton/soloist-managed/run/' . substr($hash, 0, 12),
        'packaged LMS cache keeps the runtime tree below the cache directory',
    );
    cmp_ok(length(catfile($packaged, 'native')), '<=', 100, 'packaged LMS Pulse socket path fits');
    $Slim::Utils::Prefs::values{server}{cachedir} = $long_cache;
    my $fallback = Plugins::SpotOn::Soloist::Manager::_runtime_dir_for($hash);
    like($fallback, qr{/spoton-soloist-$>/[0-9a-f]{12}\z}, 'overlong cache path falls back to a private temp directory');
    cmp_ok(length(catfile($fallback, 'native')), '<=', 100, 'fallback Pulse socket path fits');
    is((stat(File::Spec->catdir(File::Spec->tmpdir(), "spoton-soloist-$>")))[2] & 07777, 0700,
        'fallback parent directory is private');
    $Slim::Utils::Prefs::values{server}{cachedir} = $root;

    # ---- Restart backoff. ----
    $_->{synced} = 0 for $kitchen, $living;
    $_->{master} = $_ for $kitchen, $living;
    @Slim::Player::Client::clients = ($kitchen);
    my $clock = 10_000;
    no warnings 'redefine';
    local *Time::HiRes::time = sub { $clock };
    use warnings 'redefine';
    @Local::Runtime::instances = ();
    ok(Plugins::SpotOn::Soloist::Manager->start(), 'manager restarts for backoff checks');
    is(scalar @Local::Runtime::instances, 1, 'single player runtime starts');
    $Local::Runtime::instances[0]{fail_with} = 'soloist_exited';
    Plugins::SpotOn::Soloist::Manager::_poll();
    is(Plugins::SpotOn::Soloist::Manager->instanceForClient($kitchen)->state, 'failed',
        'runtime failure is detected by the health poll');
    Plugins::SpotOn::Soloist::Manager->reconcile();
    is(scalar @Local::Runtime::instances, 1, 'failed runtime is not restarted immediately');
    my $retry = Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{retries}{'00:11:22:33:44:55'};
    is($retry->{count}, 1, 'status reports the failure count');
    is($retry->{nextTry}, $clock + 15, 'first retry waits 15 seconds');

    $clock += 16;
    Plugins::SpotOn::Soloist::Manager->reconcile();
    is(scalar @Local::Runtime::instances, 2, 'failed runtime restarts after its backoff');
    $Local::Runtime::instances[1]{fail_with} = 'soloist_exited';
    Plugins::SpotOn::Soloist::Manager::_poll();
    is(Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{retries}{'00:11:22:33:44:55'}{nextTry},
        $clock + 30, 'second consecutive failure doubles the backoff');

    $clock += 31;
    Plugins::SpotOn::Soloist::Manager->reconcile();
    is(scalar @Local::Runtime::instances, 3, 'runtime restarts after the doubled backoff');
    $Local::Runtime::instances[2]{fail_with} = 'soloist_build_expired';
    Plugins::SpotOn::Soloist::Manager::_poll();
    is(Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{retries}{'00:11:22:33:44:55'}{nextTry},
        $clock + 3600, 'expired Soloist build is retried only hourly');

    ok(Plugins::SpotOn::Soloist::Manager->start(), 'explicit start resets backoff');
    is(scalar @Local::Runtime::instances, 4, 'explicit start retries an expired build immediately');
    Plugins::SpotOn::Soloist::Manager::_poll();
    $clock += 121;
    Plugins::SpotOn::Soloist::Manager->reconcile();
    is_deeply(Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{retries}, {},
        'stable runtime clears its failure history');

    # ---- LMS <-> Spotify control synchronization. ----
    my %subscribers;
    for my $subscription (@Slim::Control::Request::subscriptions) {
        my ($callback, $filter) = @$subscription;
        $subscribers{ join(',', @{ $filter->[1] || [] }) } = $callback;
    }
    my $runtime = Plugins::SpotOn::Soloist::Manager->instanceForClient($kitchen);
    my $session = $runtime->{session};
    my $live_token = $runtime->stream_token;
    my $playing = {
        connection => 'connected',
        playback   => {
            status    => 'playing',
            is_active => 1,
            item      => { uri => 'spotify:track:x', name => 'Song', duration_ms => 1000 },
        },
    };
    $session->emit({ kind => 'state', event_type => 'playback_state' }, $playing);
    ok($kitchen->isPlaying, 'Spotify playback attaches the LMS player');

    # Spotify app pauses: LMS is paused and its echo is not sent back.
    $session->{actions} = [];
    my $paused = { %$playing, playback => { %{ $playing->{playback} }, status => 'paused' } };
    $session->emit({ kind => 'playback', event_type => 'playback_changed' }, $paused);
    ok($kitchen->isPaused, 'Spotify pause pauses the LMS player');
    $subscribers{'pause,stop'}->(
        Slim::Control::Request->notification($kitchen, 'playlist', 'pause', 1),
    );
    is_deeply($session->{actions}, [], 'LMS echo of a Spotify pause is not sent back to Soloist');

    # A real LMS unpause is forwarded once.
    $subscribers{'pause,stop'}->(
        Slim::Control::Request->notification($kitchen, 'playlist', 'pause', 0),
    );
    is_deeply($session->{actions}, [['play', {}]], 'LMS unpause resumes Spotify');

    # Spotify resumes after the user stopped the LMS player: re-attach.
    $clock += 10;
    $session->{actions} = [];
    $kitchen->{playing} = 0;
    $kitchen->{paused} = 0;
    $subscribers{'pause,stop'}->(
        Slim::Control::Request->notification($kitchen, 'playlist', 'stop'),
    );
    is_deeply($session->{actions}, [], 'LMS stop is not forwarded while Spotify is already paused');
    my $plays = grep { $_->{command}[0] eq 'playlist' && $_->{command}[1] eq 'play' }
        @Slim::Control::Request::requests;
    $session->emit({ kind => 'playback', event_type => 'playback_changed' }, $playing);
    my $plays_after_resume = grep { $_->{command}[0] eq 'playlist' && $_->{command}[1] eq 'play' }
        @Slim::Control::Request::requests;
    is($plays_after_resume, $plays + 1, 'Spotify play re-attaches a stopped LMS player');
    is($kitchen->playingSong->track->url, "spoton://soloist-pcm:$live_token",
        'LMS player is back on the live Soloist stream');

    # The user starts other content on the player: release it and pause Spotify.
    $clock += 10;
    $kitchen->{song} = Local::Song->new('file:///music/local.flac');
    $subscribers{'newsong'}->(
        Slim::Control::Request->notification($kitchen, 'playlist', 'newsong'),
    );
    is($runtime->player_id, undef, 'LMS content change releases the Soloist player');
    is_deeply($session->{actions}, [['pause', {}]], 'LMS content change pauses Spotify');
    is($kitchen->playingSong->track->url, 'file:///music/local.flac',
        'releasing the player does not stop the new LMS content');
    $session->emit({ kind => 'item', event_type => 'track_changed' }, $playing);
    is($kitchen->playingSong->track->url, 'file:///music/local.flac',
        'stale track change does not reclaim the player the user took over');
    is($runtime->player_id, undef, 'player stays released after a stale track change');

    ok(Plugins::SpotOn::Soloist::Manager->stop(), 'manager stops after control checks');

    # ---- API key management from the settings page. ----
    my $M = 'Plugins::SpotOn::Soloist::Manager';
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Manager::_binary_version = sub {
        return (version => 'soloist 1.4.2', build_date => '2026-10-01', expires_at => 1);
    };
    use warnings 'redefine';

    ok(($M->removeApiKey())[0], 'stored API key can be removed');
    ok(!-e $key_file, 'removing the key deletes the protected file');
    is($Slim::Utils::Prefs::values{'plugin.spoton'}{soloistEnabled}, 0, 'removing the key switches Soloist off');
    my $setup = $M->setupStatus();
    is($setup->{state}, 'no_key', 'setup status reports a missing key');
    is($setup->{apiKey}, 0, 'setup status flags the key as absent');

    is_deeply([$M->saveApiKey("two words")], [0, 'api_key_invalid'], 'key with whitespace is rejected');
    is_deeply([$M->saveApiKey("   ")], [0, 'api_key_invalid'], 'empty key is rejected');
    ok(!-e $key_file, 'rejected keys are not written');

    my $other = catfile($root, 'unrelated-file');
    open(my $other_fh, '>', $other) or die $!;
    print {$other_fh} 'keep me';
    close($other_fh);
    symlink($other, $key_file) or die "symlink fixture: $!";

    my $before = scalar @Local::Runtime::instances;
    ok(($M->saveApiKey("  settings-secret-key\n"))[0], 'valid key is stored from the settings page');
    ok(!-l $key_file && -f $key_file, 'key replaces a symlinked key path with a regular file');
    open(my $check, '<', $other) or die $!;
    is(scalar(<$check>), 'keep me', 'symlink target is never written');
    close($check);
    is((stat($key_file))[2] & 07777, 0600, 'stored key file is owner-only');
    open(my $stored, '<', $key_file) or die $!;
    is(scalar(<$stored>), 'settings-secret-key', 'stored key is trimmed');
    close($stored);
    ok(!-e "$key_file.new", 'no temporary key file is left behind');
    ok($M->enabled, 'storing a key enables Soloist');
    is(scalar @Local::Runtime::instances, $before + 1, 'storing a key starts the player runtimes');
    is($Local::Runtime::instances[-1]{args}{api_key}, 'settings-secret-key', 'runtime receives the stored key');

    Plugins::SpotOn::Soloist::Manager::_poll();
    $setup = $M->setupStatus();
    is($setup->{state}, 'running', 'setup status reports running devices');
    is($setup->{version}, 'soloist 1.4.2', 'setup status reports the Soloist version');
    is($setup->{devices}[0]{deviceName}, 'Kitchen', 'setup status lists the Spotify device');
    is($setup->{devices}[0]{playerName}, 'Kitchen', 'setup status names the LMS player');
    my $json = JSON::PP->new->canonical->allow_blessed->encode($setup);
    my $live = $M->instanceForClient($kitchen)->stream_token;
    unlike($json, qr/settings-secret-key/, 'setup status never contains the API key');
    unlike($json, qr/\Q$live\E/, 'setup status never contains the stream token');

    $before = scalar @Local::Runtime::instances;
    ok(($M->saveApiKey('settings-secret-key'))[0], 'saving the same key again succeeds');
    is(scalar @Local::Runtime::instances, $before, 'unchanged key does not restart running devices');

    my $old_runtime = $Local::Runtime::instances[-1];
    ok(($M->saveApiKey('rotated-secret-key'))[0], 'a new key replaces the stored key');
    ok($old_runtime->{stopped}, 'devices using the previous key are stopped');
    is($Local::Runtime::instances[-1]{args}{api_key}, 'rotated-secret-key', 'devices restart with the new key');

    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::AudioPreflight::inspect = sub {
            return { tools => { soloist => '/usr/local/bin/soloist', pulseaudio => '/usr/bin/pulseaudio' } };
        };
        my $missing = $M->setupStatus();
        is($missing->{state}, 'missing_tools', 'missing host programs take precedence in the status');
        is_deeply($missing->{missing}, ['parec', 'ffmpeg'], 'missing programs are listed');
    }
    ok($M->stop(), 'manager stops after API key checks');
}

unlink($key_file);
ok(!Plugins::SpotOn::Soloist::Manager->start(), 'missing API key still fails closed');

# soloist --version parsing: version line plus the 90-day build lifetime.
{
    my $bin = catfile($root, 'fake-soloist');
    open(my $fh, '>', $bin) or die $!;
    print {$fh} "#!/bin/sh\necho 'soloist 1.4.2 (built 2026-10-01)'\necho extra\n";
    close($fh);
    chmod 0755, $bin;
    my %build = Plugins::SpotOn::Soloist::Manager::_binary_version($bin);
    is($build{version}, 'soloist 1.4.2 (built 2026-10-01)', 'first version line is reported');
    is($build{build_date}, '2026-10-01', 'ISO build date is recognized');
    is($build{expires_at}, 1790812800 + 90 * 86400, 'expiry is 90 days after the build date');

    open($fh, '>', $bin) or die $!;
    print {$fh} "#!/bin/sh\necho 'soloist 1.5.0-dev'\n";
    close($fh);
    %build = Plugins::SpotOn::Soloist::Manager::_binary_version($bin);
    is($build{version}, 'soloist 1.5.0-dev', 'replaced binary is detected without a restart');
    ok(!exists $build{expires_at}, 'no expiry is guessed without a build date');
}
is(
    Plugins::SpotOn::Soloist::Manager->statusSnapshot()->{lastError}{code},
    'api_key_missing',
    'missing API key retains stable failure code',
);

done_testing();

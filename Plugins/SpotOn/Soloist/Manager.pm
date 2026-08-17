package Plugins::SpotOn::Soloist::Manager;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use Scalar::Util qw(blessed);
use Time::HiRes ();

use constant RECONCILE_DELAY       => 0.2;
use constant RECONCILE_INTERVAL    => 15;
use constant START_STAGGER         => 2;
use constant MAX_API_KEY_BYTES     => 1024;
use constant DEFAULT_STREAM_FORMAT => 'pcm';

my ($log, $prefs, $server_prefs);
my %instances;
my $enabled = 0;
my $initialized = 0;
my $tools;
my $last_error;
my @subscriptions;

sub init {
    _ensure_lms();
    require Plugins::SpotOn::Soloist::StreamServer;
    Plugins::SpotOn::Soloist::StreamServer->init();
    _subscribe() unless $initialized;
    $initialized = 1;

    # Existing experimental installations already have a protected API-key
    # file but no preference marker. Migrate them once, while preserving an
    # explicit managed_stop choice on later restarts.
    if (_api_key_file_ready(apiKeyFile())
        && !$prefs->get('soloistConfigured')) {
        $prefs->set('soloistConfigured', 1);
        $prefs->set('soloistEnabled', 1);
    }

    if ($prefs->get('soloistEnabled') && !$::SCANNER) {
        $enabled = 1;
        require Slim::Utils::Timers;
        Slim::Utils::Timers::killTimers(__PACKAGE__, \&_autostart);
        Slim::Utils::Timers::setTimer(
            __PACKAGE__,
            Time::HiRes::time() + 1,
            \&_autostart,
        );
    }
    return 1;
}

sub baseDir {
    _ensure_lms();
    return catdir($server_prefs->get('cachedir'), 'spoton', 'soloist-managed');
}

sub apiKeyFile { return catfile(baseDir(), 'api-key') }
sub enabled { return $enabled ? 1 : 0 }

sub start {
    my ($class, $only_client) = @_;
    _ensure_lms();
    $class->init() unless $initialized;

    my $base = baseDir();
    my $ready = eval { _secure_directory($base); 1 };
    return _manager_fail('base_dir_failed', $@) unless $ready;

    my ($api_key, $key_error) = _read_api_key(apiKeyFile());
    return _manager_fail($key_error, 'Soloist API key file is unavailable')
        unless $api_key;

    my ($runtime_tools, $preflight_error) = _preflight();
    return _manager_fail($preflight_error, 'Soloist runtime preflight failed')
        unless $runtime_tools;
    $tools = $runtime_tools;

    $enabled = 1;
    $prefs->set('soloistConfigured', 1);
    $prefs->set('soloistEnabled', 1);
    $last_error = undef;

    my @clients = $only_client
        ? (_canonical_client($only_client))
        : _desired_clients();
    @clients = grep { $_ } @clients;
    _start_clients($api_key, @clients);
    $api_key = undef;
    _schedule_reconcile(RECONCILE_INTERVAL);
    return 1;
}

sub stop {
    my ($class, %args) = @_;
    _ensure_lms();
    $enabled = 0;
    unless ($args{keep_preference}) {
        $prefs->set('soloistConfigured', 1);
        $prefs->set('soloistEnabled', 0);
    }

    if ($INC{'Slim/Utils/Timers.pm'}) {
        Slim::Utils::Timers::killTimers(__PACKAGE__, \&_autostart);
        Slim::Utils::Timers::killTimers(__PACKAGE__, \&_reconcile);
        Slim::Utils::Timers::killTimers(__PACKAGE__, \&_start_one_timer);
    }
    for my $instance (values %instances) {
        eval { $instance->stop() };
    }
    %instances = ();
    return 1;
}

sub shutdown {
    my ($class) = @_;
    $class->stop(keep_preference => 1);
    if ($INC{'Slim/Control/Request.pm'}) {
        for my $subscription (@subscriptions) {
            eval { Slim::Control::Request::unsubscribe($subscription) };
        }
    }
    @subscriptions = ();
    $initialized = 0;
    if ($INC{'Plugins/SpotOn/Soloist/StreamServer.pm'}) {
        Plugins::SpotOn::Soloist::StreamServer->shutdown();
    }
    return 1;
}

sub reconcile {
    my ($class) = @_;
    return 1 unless $enabled;

    my ($api_key, $key_error) = _read_api_key(apiKeyFile());
    return _manager_fail($key_error, 'Soloist API key file is unavailable')
        unless $api_key;
    my ($runtime_tools, $preflight_error) = $tools
        ? ($tools, undef)
        : _preflight();
    return _manager_fail($preflight_error, 'Soloist runtime preflight failed')
        unless $runtime_tools;
    $tools = $runtime_tools;

    my @clients = _desired_clients();
    my %desired = map { $_->id => $_ } @clients;

    # Never tear down an active Spotify session merely because LMS topology
    # changed. This mirrors SpotOn GH #143's stream-active guard.
    for my $id (keys %instances) {
        next if $desired{$id};
        my $instance = $instances{$id};
        next if $instance->is_active();
        $instance->stop();
        delete $instances{$id};
    }

    _start_clients($api_key, @clients);
    $api_key = undef;
    _schedule_reconcile(RECONCILE_INTERVAL);
    return 1;
}

sub attachPlayer {
    my ($class, $client, %args) = @_;
    _ensure_lms();
    my $instance = $class->instanceForClient($client);
    return _manager_fail(
        'player_runtime_not_found',
        'No managed Soloist runtime exists for this LMS player',
    ) unless $instance;
    return $instance->attach_player(
        _canonical_client($client),
        format => ($args{format} || DEFAULT_STREAM_FORMAT),
        title  => $args{title},
    );
}

sub detachPlayer {
    my ($class, $client) = @_;
    if ($client) {
        my $instance = $class->instanceForClient($client);
        return 1 unless $instance;
        return $instance->detach_player();
    }
    my $ok = 1;
    for my $instance (values %instances) {
        $ok = 0 unless $instance->detach_player();
    }
    return $ok;
}

sub instanceForClient {
    my ($class, $client_or_id) = @_;
    my $client = blessed($client_or_id)
        ? $client_or_id
        : _get_client($client_or_id);
    my $id = blessed($client_or_id)
        ? eval { $client_or_id->id() }
        : $client_or_id;

    if ($client) {
        my $master = _canonical_client($client);
        $id = eval { $master->id() } if $master;

        # During a topology transition the running Soloist process can still
        # be registered under a player which has just become a slave.  Prefer
        # that active process over a newly created, idle master process so LMS
        # transport commands and protocol hooks keep targeting the live
        # Spotify session until it becomes safe to reconcile the names.
        my $active = _active_instance_for_group($master || $client);
        return $active if $active;
    }
    return $instances{$id} if $id && $instances{$id};

    # An active pre-change runtime can temporarily belong to a current member.
    if ($client && eval { $client->isSynced() }) {
        my $master = eval { $client->master() };
        if ($master) {
            return $instances{$master->id} if $instances{$master->id};
            if (eval { require Slim::Player::Sync; 1 }) {
                for my $member (Slim::Player::Sync::slaves($master)) {
                    return $instances{$member->id}
                        if $instances{$member->id}
                            && $instances{$member->id}->is_active();
                }
            }
        }
    }
    return;
}

sub instanceForToken {
    my ($class, $token) = @_;
    return unless defined $token && !ref($token)
        && $token =~ /\A[0-9a-f]{24}\z/;
    for my $instance (values %instances) {
        return $instance
            if defined $instance->stream_token()
                && $instance->stream_token() eq $token;
    }
    return;
}

sub resolveStreamPath {
    my ($class, $token, $format) = @_;
    my $instance = $class->instanceForToken($token) or return;
    return $instance->resolve_stream_path($token, $format);
}

sub newStreamPipeline {
    my ($class, $token, $format) = @_;
    my $instance = $class->instanceForToken($token) or return;
    return $instance->new_stream_pipeline($token, $format);
}

sub metadataForToken {
    my ($class, $token) = @_;
    my $instance = $class->instanceForToken($token) or return;
    return $instance->metadata();
}

sub isSoloistPlayer {
    my ($class, $client) = @_;
    my $instance = $class->instanceForClient($client) or return 0;
    return $instance->player_id() ? 1 : 0;
}

sub sendActionForClient {
    my ($class, $client, $action, %args) = @_;
    my $instance = $class->instanceForClient($client) or return 0;
    return $instance->send_action($action, %args);
}

sub statusSnapshot {
    _ensure_lms();
    my %players = map {
        $_ => $instances{$_}->status_snapshot()
    } sort keys %instances;
    my @ordered = map { $instances{$_} } sort keys %instances;
    my ($representative) = grep { $_->is_active() } @ordered;
    $representative ||= $ordered[0];
    my $single = $representative
        ? $representative->status_snapshot()
        : {};

    my $overall = !$enabled ? 'stopped'
        : !@ordered ? 'waiting_players'
        : grep($_->state() eq 'running', @ordered) ? 'running'
        : grep($_->state() eq 'starting', @ordered) ? 'starting'
        : 'failed';

    return {
        %$single,
        state       => $overall,
        enabled     => $enabled ? 1 : 0,
        baseDir     => baseDir(),
        apiKeyFile  => apiKeyFile(),
        apiKeyReady => _api_key_file_ready(apiKeyFile()),
        playerCount => scalar(@ordered),
        players     => \%players,
        lastError   => $last_error || $single->{lastError},
    };
}

# Compatibility test/diagnostic hook: advance every asynchronous runtime once.
sub _poll {
    $_->poll_now() for values %instances;
}

sub _autostart { __PACKAGE__->start() }

sub _start_clients {
    my ($api_key, @clients) = @_;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_start_one_timer);

    my @pending;
    for my $client (@clients) {
        next unless $client;

        $client = _canonical_client($client) || next;
        my $id = eval { $client->id() } || next;

        # If an active runtime is temporarily registered under another member
        # of this sync group, it already represents the whole group.  Starting
        # another Spotify endpoint for the new master would create a duplicate
        # device and could steal commands from the uninterrupted session.
        my $active = _active_instance_for_group($client);
        next if $active && $active->client_id() ne $id;

        if ($instances{$id} && $instances{$id}->state() ne 'failed') {
            _ensure_instance($client, $api_key);
        }
        else {
            push @pending, $client;
        }
    }

    for my $index (0 .. $#pending) {
        if ($index == 0) {
            _ensure_instance($pending[$index], $api_key);
            next;
        }
        Slim::Utils::Timers::setTimer(
            __PACKAGE__,
            Time::HiRes::time() + ($index * START_STAGGER),
            \&_start_one_timer,
            $pending[$index],
        );
    }
}

sub _start_one_timer {
    my (undef, $client) = @_;
    return unless $enabled && $client;
    my ($api_key) = _read_api_key(apiKeyFile());
    return unless $api_key;
    _ensure_instance($client, $api_key);
    $api_key = undef;
}

sub _ensure_instance {
    my ($client, $api_key) = @_;
    $client = _canonical_client($client) or return;
    my $id = eval { $client->id() } or return;
    my $device_name = _device_name_for_client($client);

    my $instance = $instances{$id};
    if ($instance && $instance->device_name() ne $device_name) {
        if ($instance->is_active()) {
            $log->is_info && $log->info(
                "Soloist name change for $id deferred while playback is active"
            );
            return $instance;
        }
        $instance->stop();
        delete $instances{$id};
        undef $instance;
    }
    if ($instance && $instance->state() eq 'failed') {
        $instance->stop();
        delete $instances{$id};
        undef $instance;
    }
    return $instance if $instance;

    require Plugins::SpotOn::Soloist::PlayerRuntime;
    my $player_dir = catdir(baseDir(), 'players', md5_hex($id));
    $instance = Plugins::SpotOn::Soloist::PlayerRuntime->new(
        client_id   => $id,
        device_name => $device_name,
        base_dir    => $player_dir,
        api_key     => $api_key,
        tools       => $tools,
        verbose     => $prefs->get('diagnosticMode') ? 1 : 0,
        on_update   => \&_on_instance_update,
        on_status   => sub { },
        on_error    => sub {
            my ($failed_instance, $code, $message) = @_;
            $last_error = {
                code     => $code,
                message  => $message,
                playerId => $failed_instance->client_id(),
            };
        },
    );
    $instances{$id} = $instance;
    unless ($instance->start()) {
        $last_error = $instance->status_snapshot()->{lastError};
        return;
    }
    return $instance;
}

sub _on_instance_update {
    my ($instance, $event, $snapshot) = @_;
    return unless $instance && ref($event) eq 'HASH';
    $snapshot ||= $instance->session_snapshot() || {};
    my $playback = $snapshot->{playback} || {};
    my $kind = $event->{kind} || '';

    if (($kind eq 'state' || $kind eq 'device')
        && defined $playback->{is_active}
        && !$playback->{is_active}) {
        $instance->detach_player() if $instance->player_id();
        return;
    }

    if (($kind eq 'state' || $kind eq 'playback' || $kind eq 'item')
        && $playback->{is_active}
        && ($playback->{status} || '') eq 'playing'
        && !$instance->player_id()) {
        my $client = _get_client($instance->client_id());
        if ($client) {
            my $meta = _metadata_from_snapshot($instance, $snapshot);
            $instance->attach_player(
                _canonical_client($client),
                format => DEFAULT_STREAM_FORMAT,
                title  => $meta ? _display_title($meta) : $instance->device_name(),
            );
        }
    }

    _apply_metadata($instance, $snapshot, $kind eq 'item' ? 1 : 0)
        if $kind eq 'state' || $kind eq 'item';
    _apply_playback_status($instance, $playback->{status})
        if $kind eq 'state' || $kind eq 'playback';
    _apply_position($instance, $playback->{position}, $kind eq 'state' ? 1 : 0)
        if $kind eq 'state' || $kind eq 'position';
}

sub _metadata_from_snapshot {
    my ($instance, $snapshot) = @_;
    my $item = (($snapshot || {})->{playback} || {})->{item};
    return unless ref($item) eq 'HASH' && $item->{name};

    my $artist = join(', ', grep { length($_) } map {
        ref($_) eq 'HASH' ? ($_->{name} || '') : ''
    } @{ $item->{creators} || [] });
    my $album = ref($item->{parent}) eq 'HASH'
        ? ($item->{parent}{name} || '')
        : '';
    my %rank = (small => 1, default => 2, large => 3, xlarge => 4);
    my ($cover) = map { $_->{url} }
        sort {
            ($rank{$b->{size} || ''} || 0)
                <=> ($rank{$a->{size} || ''} || 0)
        }
        grep {
            ref($_) eq 'HASH'
                && defined $_->{url}
                && $_->{url} =~ m{\Ahttps?://}i
        } @{ $item->{covers} || [] };
    $cover ||= '/html/images/cover.png';

    my $duration = ($item->{duration_ms} || 0) / 1000;
    my $token = $instance->stream_token();
    my $url = $token ? "spoton://soloist-pcm:$token" : undef;
    return {
        title        => $item->{name},
        artist       => $artist,
        album        => $album,
        duration     => $duration,
        cover        => $cover,
        icon         => $cover,
        url          => $url,
        spotifyUri   => $item->{uri},
        bitrate      => '1411k',
        originalType => 'PCM, Spotify Connect (Soloist)',
        type         => 'PCM, Spotify Connect (Soloist)',
    };
}

sub _apply_metadata {
    my ($instance, $snapshot, $track_changed) = @_;
    my $meta = _metadata_from_snapshot($instance, $snapshot) or return;
    $instance->set_metadata($meta);

    my $client = _get_client($instance->player_id() || $instance->client_id());
    return unless $client;
    $client = _canonical_client($client) || $client;
    my $song = eval { $client->playingSong() } or return;
    eval { $song->pluginData(info => { %$meta }) };
    eval { $song->duration($meta->{duration}) } if $meta->{duration};

    my $logical_url = eval { $song->track->url() }
        || eval { $song->streamUrl() }
        || $meta->{url};
    my $stream_url = eval { $song->streamUrl() };
    my $display = _display_title($meta);
    eval {
        require Slim::Music::Info;
        Slim::Music::Info::setCurrentTitle($logical_url, $display, $client);
        Slim::Music::Info::setCurrentTitle($stream_url, $display, $client)
            if $stream_url && $stream_url ne $logical_url;
    };

    if ($track_changed) {
        my $elapsed = eval { $client->songElapsedSeconds() } || 0;
        eval { $song->startOffset(0 - $elapsed) };
        eval { $client->playPoint(undef) };
    }
    if ($meta->{duration}) {
        eval {
            $client->streamingProgressBar({
                url      => $stream_url || $logical_url,
                duration => $meta->{duration},
            });
        };
    }
    eval { $client->currentPlaylistUpdateTime(Time::HiRes::time()) }
        if $client->can('currentPlaylistUpdateTime');
    eval {
        require Slim::Control::Request;
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    };
}

sub _apply_playback_status {
    my ($instance, $status) = @_;
    return unless $instance->player_id();
    return unless defined $status && ($status eq 'playing' || $status eq 'paused');
    my $client = _get_client($instance->player_id()) or return;
    my $is_playing = eval { $client->isPlaying() } ? 1 : 0;
    return if ($status eq 'playing' && $is_playing)
        || ($status eq 'paused' && !$is_playing);

    require Slim::Control::Request;
    my $request = Slim::Control::Request->new(
        $client->id,
        ['pause', $status eq 'paused' ? 1 : 0],
    );
    return unless $request;
    $request->source(__PACKAGE__) if $request->can('source');
    $request->execute();
}

sub _apply_position {
    my ($instance, $position, $force) = @_;
    return unless $instance->player_id() && ref($position) eq 'HASH';
    return unless defined $position->{position_ms}
        && $position->{position_ms} =~ /\A\d+(?:\.\d+)?\z/;
    my $client = _get_client($instance->player_id()) or return;
    my $song = eval { $client->playingSong() } or return;
    my $target = $position->{position_ms} / 1000;
    if (($position->{speed} || 0) > 0
        && $position->{timestamp_ms}
        && $position->{timestamp_ms} =~ /\A\d+\z/) {
        my $age = (Time::HiRes::time() * 1000 - $position->{timestamp_ms}) / 1000;
        $target += $age if $age > 0 && $age < 30;
    }
    my $current = eval { $client->songElapsedSeconds() } || 0;
    return unless $force || abs($target - $current) > 1.5;
    my $elapsed = eval { $client->songElapsedSeconds() } || 0;
    eval { $song->startOffset($target - $elapsed) };
    eval {
        require Slim::Control::Request;
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    };
}

sub _display_title {
    my ($meta) = @_;
    return '' unless ref($meta) eq 'HASH';
    return $meta->{artist}
        ? "$meta->{artist} - $meta->{title}"
        : ($meta->{title} || 'Spotify');
}

sub _subscribe {
    return unless eval {
        require Slim::Control::Request;
        Slim::Control::Request->can('subscribe');
    };

    my $topology = sub { _schedule_reconcile(RECONCILE_DELAY) };
    Slim::Control::Request::subscribe(
        $topology,
        [['client'], ['new', 'disconnect']],
    );
    push @subscriptions, $topology;

    my $sync = sub {
        my ($request) = @_;
        return if $request->can('isNotCommand')
            && $request->isNotCommand([['sync']]);
        _schedule_reconcile(RECONCILE_DELAY);
    };
    Slim::Control::Request::subscribe($sync, [['sync']]);
    push @subscriptions, $sync;

    my $pause = sub {
        my ($request) = @_;
        return if eval { $request->source() }
            && $request->source() eq __PACKAGE__;
        my $client = eval { $request->client() } or return;
        my $instance = __PACKAGE__->instanceForClient($client) or return;
        return unless $instance->player_id();
        my $newvalue = eval { $request->getParam('_newvalue') };
        my $unpause = eval {
            $request->isCommand([['playlist'], ['pause']]) && !$newvalue
        };
        $instance->send_action($unpause ? 'play' : 'pause');
    };
    Slim::Control::Request::subscribe(
        $pause,
        [['playlist'], ['pause', 'stop']],
    );
    push @subscriptions, $pause;

    my $jump = sub {
        my ($request) = @_;
        return if eval { $request->source() }
            && $request->source() eq __PACKAGE__;
        my $client = eval { $request->client() } or return;
        my $instance = __PACKAGE__->instanceForClient($client) or return;
        return unless $instance->player_id();
        my $index = eval { $request->getParam('_index') };
        $instance->send_action('next') if defined $index && $index eq '+1';
        $instance->send_action('previous')
            if defined $index && ($index eq '-1' || $index eq '+0');
    };
    Slim::Control::Request::subscribe(
        $jump,
        [['playlist'], ['jump', 'index']],
    );
    push @subscriptions, $jump;
}

sub _schedule_reconcile {
    my ($delay) = @_;
    return unless $enabled;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_reconcile);
    Slim::Utils::Timers::setTimer(
        __PACKAGE__,
        Time::HiRes::time() + $delay,
        \&_reconcile,
    );
}

sub _reconcile { __PACKAGE__->reconcile() }

sub _desired_clients {
    return () unless eval {
        require Slim::Player::Client;
        Slim::Player::Client->can('clients');
    };
    my %desired;
    for my $client (Slim::Player::Client::clients()) {
        next unless blessed($client) && $client->can('id');
        my $target = _canonical_client($client) || next;
        my $id = eval { $target->id() } || next;
        $desired{$id} ||= $target;
    }
    return map { $desired{$_} } sort keys %desired;
}

sub _canonical_client {
    my ($client) = @_;
    return unless blessed($client) && $client->can('id');
    my $master = eval { $client->master() } if $client->can('master');
    return $master || $client;
}

sub _active_instance_for_group {
    my ($client) = @_;
    $client = _canonical_client($client) or return;
    my $master_id = eval { $client->id() } or return;

    for my $instance (values %instances) {
        next unless $instance->is_active();
        my $member_id = $instance->player_id() || $instance->client_id();
        my $member = _get_client($member_id) or next;
        my $member_master = _canonical_client($member) or next;
        return $instance
            if eval { $member_master->id() eq $master_id };
    }
    return;
}

sub _get_client {
    my ($id) = @_;
    return unless defined $id;
    return unless eval { require Slim::Player::Client; 1 };
    return Slim::Player::Client::getClient($id);
}

sub _device_name_for_client {
    my ($client) = @_;
    my $name = eval {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->deviceNameForClient($client);
    };
    return $name if defined $name && length($name);
    my $fallback = eval { $client->name() }
        || eval { $client->id() }
        || 'SpotOn';
    return substr($fallback, 0, 60);
}

sub _preflight {
    require Plugins::SpotOn::Soloist::AudioPreflight;
    require Plugins::SpotOn::Soloist::Transport;
    my $websocket = Plugins::SpotOn::Soloist::Transport->websocket_available();
    return (undef, 'lms_simplews_missing') unless $websocket;
    my $preflight = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
        websocket_available => $websocket,
    );
    my $found = $preflight->{tools} || {};
    for my $required (qw(soloist pulseaudio parec ffmpeg)) {
        return (undef, "missing_$required") unless $found->{$required};
    }
    return ({ %$found }, undef);
}

sub _manager_fail {
    my ($code, $message) = @_;
    $last_error = {
        code    => $code || 'managed_failed',
        message => _clean_message($message),
    };
    return 0;
}

sub _read_api_key {
    my ($path) = @_;
    my @stat = lstat($path);
    return (undef, 'api_key_missing') unless @stat;
    return (undef, 'api_key_symlink') if -l _;
    return (undef, 'api_key_not_file') unless -f _;
    return (undef, 'api_key_wrong_owner') unless $stat[4] == $>;
    return (undef, 'api_key_permissions') if ($stat[2] & 0077) != 0;
    return (undef, 'api_key_size')
        unless $stat[7] >= 1 && $stat[7] <= MAX_API_KEY_BYTES;

    open(my $fh, '<', $path) or return (undef, 'api_key_read_failed');
    binmode($fh);
    my $bytes = read($fh, my $key, MAX_API_KEY_BYTES + 1);
    close($fh);
    return (undef, 'api_key_read_failed') unless defined $bytes;
    return (undef, 'api_key_size') if $bytes > MAX_API_KEY_BYTES;
    $key =~ s/^\s+|\s+$//g;
    return (undef, 'api_key_invalid')
        unless length($key) && $key !~ /[\x00-\x1f\x7f]/;
    return ($key, undef);
}

sub _api_key_file_ready {
    my ($path) = @_;
    my ($key, $error) = _read_api_key($path);
    $key = undef;
    return $error ? 0 : 1;
}

sub _secure_directory {
    my ($path) = @_;
    make_path($path, { mode => 0700 }) unless -e $path;
    my @stat = lstat($path);
    die 'Unable to inspect managed runtime directory' unless @stat;
    die 'Managed runtime directory must not be a symlink' if -l _;
    die 'Managed runtime path is not a directory' unless -d _;
    die 'Managed runtime directory has the wrong owner' unless $stat[4] == $>;
    chmod 0700, $path or die "Unable to protect managed runtime directory: $!";
    return 1;
}

sub _clean_message {
    my ($message) = @_;
    $message = '' unless defined $message;
    $message = "$message";
    $message =~ s/[\x00-\x1f\x7f]+/ /g;
    $message =~ s/^\s+|\s+$//g;
    return $message;
}

sub _ensure_lms {
    return if $server_prefs;
    require Slim::Utils::Log;
    require Slim::Utils::Prefs;
    $log = Slim::Utils::Log->logger('plugin.spoton');
    $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    $server_prefs = Slim::Utils::Prefs::preferences('server');
}

1;

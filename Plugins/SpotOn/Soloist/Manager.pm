package Plugins::SpotOn::Soloist::Manager;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use File::Path qw(make_path);
use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use Cwd qw(abs_path);
use Scalar::Util qw(blessed);
use Time::HiRes ();
use Time::Local qw(timegm);

use constant RECONCILE_DELAY       => 0.2;
use constant RECONCILE_INTERVAL    => 15;
use constant START_STAGGER         => 2;
use constant MAX_API_KEY_BYTES     => 1024;
use constant DEFAULT_STREAM_FORMAT => 'pcm';
use constant AUTOSTART_RETRY       => 60;

# Failed runtimes are restarted with exponential backoff instead of on every
# reconcile pass.  An expired Soloist build cannot recover without a new
# binary, so it is retried rarely; managed_start resets all backoff.
use constant RETRY_BASE            => 15;
use constant RETRY_MAX             => 600;
use constant RETRY_EXPIRED         => 3600;
use constant STABLE_AFTER          => 120;

# LMS reports our own pause/stop requests back as unsourced notifications.
# Ignore those echoes so they cannot override a newer Spotify app command.
use constant ECHO_WINDOW           => 2;

# A freshly requested LMS stream needs a moment before playingSong reflects it.
use constant REATTACH_GRACE        => 5;

# PulseAudio's Unix socket path must fit sockaddr_un.sun_path (108 bytes);
# Runtime rejects anything above this conservative limit.
use constant MAX_SOCKET_PATH       => 100;

# Spotify Soloist builds stop working 90 days after their build date.
use constant BUILD_LIFETIME_DAYS   => 90;
use constant VERSION_TIMEOUT       => 5;

# Optional automatic updates of the SpotOn-managed Soloist binary.
use constant UPDATE_CHECK_FIRST    => 600;
use constant UPDATE_CHECK_INTERVAL => 86_400;

my @REQUIRED_TOOLS = qw(soloist pulseaudio parec ffmpeg);

my ($log, $prefs, $server_prefs);
my %instances;
my $enabled = 0;
my $initialized = 0;
my $tools;
my $last_error;
my @subscriptions;
my %failures;
my %lms_echo;
my %attach_block;
my %version_cache;
my %instance_binary;
my $installer;

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

    __PACKAGE__->scheduleUpdateCheck(UPDATE_CHECK_FIRST) unless $::SCANNER;

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

    # An explicit (re)start is the user's signal that the host changed, for
    # example after installing a newer Soloist build.
    %failures = ();
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
    %failures = ();
    %lms_echo = ();
    %attach_block = ();
    %instance_binary = ();
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
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_update_check)
        if $INC{'Slim/Utils/Timers.pm'};
    if ($INC{'Plugins/SpotOn/Soloist/StreamServer.pm'}) {
        Plugins::SpotOn::Soloist::StreamServer->shutdown();
    }
    return 1;
}

sub reconcile {
    my ($class) = @_;
    return 1 unless $enabled;

    # Keep reconciling even when this pass cannot proceed: a transiently
    # unreadable key file must not stop supervision for good.
    _schedule_reconcile(RECONCILE_INTERVAL);

    my ($api_key, $key_error) = _read_api_key(apiKeyFile());
    return _manager_fail($key_error, 'Soloist API key file is unavailable')
        unless $api_key;
    my ($runtime_tools, $preflight_error) = $tools
        ? ($tools, undef)
        : _preflight();
    return _manager_fail($preflight_error, 'Soloist runtime preflight failed')
        unless $runtime_tools;
    $tools = $runtime_tools;

    my $now = Time::HiRes::time();
    for my $id (keys %failures) {
        my $instance = $instances{$id};
        delete $failures{$id}
            if $instance && $instance->state() eq 'running'
                && $instance->running_since()
                && $now - $instance->running_since() >= STABLE_AFTER;
    }

    # A replaced Soloist binary (downloaded by SpotOn or installed by hand)
    # takes effect as soon as a device is idle; playback is never cut off.
    my $current_binary = _binary_identity($tools->{soloist});
    for my $id (keys %instances) {
        my $instance = $instances{$id};
        next if $instance->is_active() || $instance->state() eq 'failed';
        next unless defined $current_binary && defined $instance_binary{$id}
            && $instance_binary{$id} ne $current_binary;
        $log->info('Soloist device "' . $instance->device_name()
            . '" restarts with the new Soloist build') if $log->is_info;
        $instance->stop();
        delete $instances{$id};
        delete $instance_binary{$id};
    }

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
    return 1;
}

# Store the Soloist API key from the settings page.  The key is written to the
# same protected file an administrator would create by hand (owner-only,
# never a symlink) and is never placed in a preference, log or response.
# Returns (1) or (0, $error_code).
sub saveApiKey {
    my ($class, $key) = @_;
    _ensure_lms();
    $key = '' unless defined $key && !ref($key);
    $key =~ s/^\s+|\s+$//g;
    return (0, 'api_key_invalid')
        unless length($key) && length($key) <= MAX_API_KEY_BYTES
            && $key =~ /\A[\x21-\x7e]+\z/;

    my ($current) = _read_api_key(apiKeyFile());
    my $unchanged = defined $current && $current eq $key;
    $current = undef;
    if ($unchanged) {
        $key = undef;
        # Saving the same key again is the way to retry a failed backend,
        # for example after replacing an expired Soloist build.
        $class->start();
        return (1);
    }

    my $written = eval { _write_api_key($key); 1 };
    my $error = $@;
    $key = undef;
    unless ($written) {
        $log->warn('Soloist backend: unable to store API key - ' . _clean_message($error));
        return (0, 'api_key_write_failed');
    }
    $log->info('Soloist backend: API key updated');

    # Running devices hold the previous key; restart them with the new one.
    $class->stop(keep_preference => 1) if $enabled;
    $class->start();
    return (1);
}

sub removeApiKey {
    my ($class) = @_;
    _ensure_lms();
    $class->stop();
    my $path = apiKeyFile();
    if (-e $path || -l $path) {
        unless (unlink($path)) {
            $log->warn("Soloist backend: unable to remove API key file: $!");
            return (0, 'api_key_remove_failed');
        }
    }
    $last_error = undef;
    $log->info('Soloist backend: API key removed, backend switched off');
    return (1);
}

# Summary for the settings and status pages.  Contains no API key, stream
# token or stream URL.
sub setupStatus {
    my ($class) = @_;
    _ensure_lms();

    my ($key, $key_error) = _read_api_key(apiKeyFile());
    $key = undef;

    require Plugins::SpotOn::Soloist::AudioPreflight;
    require Plugins::SpotOn::Soloist::Transport;
    my $websocket = Plugins::SpotOn::Soloist::Transport->websocket_available();
    my $soloist_installer = _installer();
    my $managed = $soloist_installer->installed_binary();
    my $found = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
        websocket_available => $websocket,
        ($managed ? (soloist_binary => $managed) : ()),
    )->{tools} || {};
    my %tools = map { $_ => $found->{$_} } @REQUIRED_TOOLS;
    my $managed_path = $managed ? (abs_path($managed) || $managed) : undef;
    my $binary_source = !$tools{soloist} ? undef
        : defined $managed_path && $tools{soloist} eq $managed_path ? 'managed'
        : 'system';
    my @missing = grep { !$tools{$_} } @REQUIRED_TOOLS;
    push @missing, 'lms_simplews' unless $websocket;
    unshift @missing, 'linux' unless $^O eq 'linux';

    my %build;
    %build = _binary_version($tools{soloist}) if $tools{soloist};

    my $now = Time::HiRes::time();
    my @devices;
    for my $id (sort keys %instances) {
        my $instance = $instances{$id};
        my $snapshot = $instance->status_snapshot();
        my $playback = (($snapshot->{session} || {})->{playback}) || {};
        my $item = ref($playback->{item}) eq 'HASH' ? $playback->{item} : {};
        my $client = _get_client($id);
        my $failure = $failures{$id};
        push @devices, {
            playerId   => $id,
            playerName => ($client && eval { $client->name() }) || $id,
            deviceName => $instance->device_name(),
            state      => $instance->state(),
            connection => $snapshot->{sessionStatus},
            active     => $playback->{is_active} ? 1 : 0,
            playback   => $playback->{status},
            track      => defined $item->{name}
                ? _display_title(_item_summary($item))
                : undef,
            attached   => $instance->player_id() ? 1 : 0,
            lastError  => $snapshot->{lastError},
            retry      => $failure ? {
                count => $failure->{count},
                code  => $failure->{code},
                in    => int(($failure->{next_try} > $now ? $failure->{next_try} - $now : 0) + 0.5),
            } : undef,
        };
    }

    my $expired = grep {
        ($_->{retry} && ($_->{retry}{code} || '') eq 'runtime_soloist_build_expired')
            || ($_->{lastError} && ($_->{lastError}{code} || '') eq 'runtime_soloist_build_expired')
    } @devices;
    my $overall = $class->statusSnapshot()->{state};
    my $state = @missing                        ? 'missing_tools'
              : ($key_error || '') eq 'api_key_missing' ? 'no_key'
              : $key_error                      ? 'key_error'
              : !$enabled                       ? 'disabled'
              : $expired                        ? 'expired'
              : $overall;

    return {
        state        => $state,
        enabled      => $enabled ? 1 : 0,
        apiKey       => $key_error ? 0 : 1,
        apiKeyError  => $key_error,
        apiKeyFile   => apiKeyFile(),
        tools        => \%tools,
        missing      => \@missing,
        version      => $build{version},
        binarySource => $binary_source,
        installer    => $soloist_installer->status(),
        autoUpdate   => $prefs->get('soloistAutoUpdate') ? 1 : 0,
        buildDate    => $build{build_date},
        expiresAt    => $build{expires_at},
        expiresInDays => defined $build{expires_at}
            ? int(($build{expires_at} - $now) / 86_400)
            : undef,
        devices      => \@devices,
        lastError    => $last_error,
    };
}

sub managedBinary {
    _ensure_lms();
    return _installer()->installed_binary();
}

# Download the current Soloist build for this host from Spotify and install
# it into the private data directory.  Asynchronous; see installerStatus().
sub installLatest {
    my ($class) = @_;
    _ensure_lms();
    my $prepared = eval { _secure_directory(baseDir()); 1 };
    return (0, 'base_dir_failed') unless $prepared;
    $log->info('Soloist: downloading the current build from Spotify');
    my ($ok, $error) = _installer()->install(on_done => \&_on_binary_installed);
    return $ok ? (1) : (0, $error);
}

sub installerStatus {
    _ensure_lms();
    return _installer()->status();
}

sub scheduleUpdateCheck {
    my ($class, $delay) = @_;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_update_check);
    Slim::Utils::Timers::setTimer(
        __PACKAGE__,
        Time::HiRes::time() + (defined $delay ? $delay : UPDATE_CHECK_INTERVAL),
        \&_update_check,
    );
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
        retries     => {
            map {
                $_ => {
                    count  => $failures{$_}{count},
                    code   => $failures{$_}{code},
                    nextTry => $failures{$_}{next_try},
                }
            } sort keys %failures
        },
        lastError   => $last_error || $single->{lastError},
    };
}

# Compatibility test/diagnostic hook: advance every asynchronous runtime once.
sub _poll {
    $_->poll_now() for values %instances;
}

sub _installer {
    $installer ||= do {
        require Plugins::SpotOn::Soloist::Installer;
        Plugins::SpotOn::Soloist::Installer->new(
            base_dir   => baseDir(),
            version_of => \&_binary_version,
        );
    };
    return $installer;
}

sub _on_binary_installed {
    my ($ok, $info_or_code, $message) = @_;
    unless ($ok) {
        $log->warn('Soloist: download of the current build failed ('
            . ($info_or_code || 'unknown') . ')'
            . (defined $message && length $message ? ": $message" : ''));
        return;
    }

    $log->info('Soloist: installed ' . ($info_or_code->{version} || 'new build'));
    # Re-run preflight so the managed binary is picked up, and give failed
    # devices (for example after an expired build) an immediate retry.
    $tools = undef;
    %failures = ();
    %version_cache = ();
    if ($enabled) {
        _schedule_reconcile(RECONCILE_DELAY);
    }
    elsif ($prefs->get('soloistEnabled')) {
        __PACKAGE__->start();
    }
}

sub _update_check {
    __PACKAGE__->scheduleUpdateCheck(UPDATE_CHECK_INTERVAL);
    return unless $prefs->get('soloistAutoUpdate');
    my $soloist_installer = _installer();
    return if $soloist_installer->busy() || !$soloist_installer->supported();
    $soloist_installer->check_for_update(sub {
        my ($available, $detail) = @_;
        if (!defined $available) {
            $log->warn("Soloist: update check failed: " . _clean_message($detail));
            return;
        }
        return unless $available;
        $log->info('Soloist: a new build is available');
        __PACKAGE__->installLatest();
    });
}

sub _binary_identity {
    my ($path) = @_;
    return undef unless defined $path;
    my @stat = stat($path) or return undef;
    return join(':', $path, @stat[0, 1, 7, 9]);
}

sub _autostart {
    return if __PACKAGE__->start();
    return unless $prefs->get('soloistEnabled');

    # The API key or a host dependency may appear after LMS has started.
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_autostart);
    Slim::Utils::Timers::setTimer(
        __PACKAGE__,
        Time::HiRes::time() + AUTOSTART_RETRY,
        \&_autostart,
    );
}

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
        elsif (!_retry_pending($id)) {
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
    my $hash = md5_hex($id);
    my $player_dir = catdir(baseDir(), 'players', $hash);
    my $runtime_dir = eval { _runtime_dir_for($hash) };
    unless ($runtime_dir) {
        _manager_fail('runtime_dir_failed', $@);
        return;
    }
    $instance = Plugins::SpotOn::Soloist::PlayerRuntime->new(
        client_id   => $id,
        device_name => $device_name,
        base_dir    => $player_dir,
        runtime_dir => $runtime_dir,
        api_key     => $api_key,
        tools       => $tools,
        verbose     => $prefs->get('diagnosticMode') ? 1 : 0,
        on_update   => \&_on_instance_update,
        on_status   => sub {
            my ($status, $snapshot) = @_;
            $log->info("Soloist device \"$device_name\" is running")
                if $status eq 'running' && $log->is_info;
        },
        on_error    => sub {
            my ($failed_instance, $code, $message) = @_;
            $last_error = {
                code     => $code,
                message  => $message,
                playerId => $failed_instance->client_id(),
            };
            _register_failure($failed_instance, $code, $message)
                if $failed_instance->state() eq 'failed';
        },
    );
    $instances{$id} = $instance;
    $instance_binary{$id} = _binary_identity($tools->{soloist});
    unless ($instance->start()) {
        $last_error = $instance->status_snapshot()->{lastError};
        return;
    }
    return $instance;
}

# The per-player data directory keeps the full player hash so Soloist's stored
# Spotify session survives upgrades.  The runtime tree holding the PulseAudio
# socket is kept short instead: a packaged LMS cache directory such as
# /var/lib/squeezeboxserver/cache plus the full hash exceeds sun_path.
sub _runtime_dir_for {
    my ($hash) = @_;
    my $short = substr($hash, 0, 12);
    my $dir = catdir(baseDir(), 'run', $short);
    return $dir if length(catfile($dir, 'native')) <= MAX_SOCKET_PATH;

    my $fallback = catdir(File::Spec->tmpdir(), "spoton-soloist-$>");
    _secure_directory($fallback);
    return catdir($fallback, $short);
}

sub _register_failure {
    my ($instance, $code, $message) = @_;
    my $id = $instance->client_id();
    my $failure = $failures{$id} ||= { count => 0 };
    $failure->{count}++;
    $code = '' unless defined $code;

    my $delay = RETRY_BASE * 2 ** ($failure->{count} - 1);
    $delay = RETRY_MAX if $delay > RETRY_MAX;
    $delay = RETRY_EXPIRED if $code eq 'runtime_soloist_build_expired';
    $failure->{code} = $code;
    $failure->{next_try} = Time::HiRes::time() + $delay;

    $log->warn(sprintf(
        'Soloist device "%s" failed (%s: %s); retrying in %d s',
        $instance->device_name(),
        $code,
        _clean_message($message),
        $delay,
    )) if $log;
}

sub _retry_pending {
    my ($id) = @_;
    my $failure = $failures{$id} or return 0;
    return $failure->{next_try} > Time::HiRes::time() ? 1 : 0;
}

sub _expect_echo {
    my ($instance, $action) = @_;
    $lms_echo{ $instance->client_id() } = {
        action => $action,
        until  => Time::HiRes::time() + ECHO_WINDOW,
    };
}

sub _consume_echo {
    my ($instance, $action) = @_;
    my $echo = $lms_echo{ $instance->client_id() } or return 0;
    if ($echo->{until} < Time::HiRes::time()) {
        delete $lms_echo{ $instance->client_id() };
        return 0;
    }
    return 0 unless $echo->{action} eq $action;
    delete $lms_echo{ $instance->client_id() };
    return 1;
}

sub _soloist_status {
    my ($instance) = @_;
    my $snapshot = $instance->session_snapshot() || {};
    return (($snapshot->{playback} || {})->{status}) || '';
}

# True while the attached LMS player is still on this runtime's live stream.
# The user may have stopped it or started other content in the meantime.
sub _player_on_stream {
    my ($instance) = @_;
    my $token = $instance->stream_token() or return 0;
    my $client = _get_client($instance->player_id()) or return 0;
    $client = _canonical_client($client) || $client;
    return 0 if $client->can('isStopped') && eval { $client->isStopped() };
    my $song = eval { $client->playingSong() } or return 0;
    my $url = eval { $song->track->url() } || eval { $song->streamUrl() } || '';
    return index($url, $token) >= 0 ? 1 : 0;
}

sub _needs_attach {
    my ($instance) = @_;
    return 1 unless $instance->player_id();
    my $attached_at = $instance->attached_at() || 0;
    return 0 if Time::HiRes::time() - $attached_at < REATTACH_GRACE;
    return _player_on_stream($instance) ? 0 : 1;
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

    # Attach on activation, and re-attach when Spotify plays while the LMS
    # player was stopped or switched to other content in the meantime.  A
    # track change carries no status of its own: its snapshot can still say
    # "playing" just after LMS asked Soloist to pause, so it may only perform
    # a first attach and never reclaim a player the user just took over.
    my $attach_event = $kind eq 'state' || $kind eq 'playback'
        || ($kind eq 'item'
            && !$instance->player_id()
            && ($attach_block{ $instance->client_id() } || 0) <= Time::HiRes::time());
    if ($attach_event
        && $playback->{is_active}
        && ($playback->{status} || '') eq 'playing'
        && _needs_attach($instance)) {
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
    $client = _canonical_client($client) || $client;

    # Only resume a paused player and only pause a playing one.  A stopped
    # player is restarted by the attach path, never by "pause 0".
    if ($status eq 'playing') {
        return unless eval { $client->isPaused() };
    }
    else {
        return unless eval { $client->isPlaying() };
    }

    _expect_echo($instance, $status eq 'paused' ? 'pause' : 'play');
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
        my $is_pause = eval { $request->isCommand([['playlist'], ['pause']]) };
        my $action = !$is_pause ? 'stop' : $newvalue ? 'pause' : 'play';
        return if _consume_echo($instance, $action);

        # Forward only real state changes to Soloist.
        my $status = _soloist_status($instance);
        if ($action eq 'play') {
            return if $status eq 'playing';
            $instance->send_action('play');
        }
        else {
            return unless $status eq 'playing' || $status eq 'buffering';
            $instance->send_action('pause');
        }
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

    # Playing other content on the LMS player releases it from Spotify.  Pause
    # Soloist as well; otherwise the app keeps showing it as playing into the
    # private null sink with nobody listening.
    my $newsong = sub {
        my ($request) = @_;
        my $client = eval { $request->client() } or return;
        my $instance = __PACKAGE__->instanceForClient($client) or return;
        return unless $instance->player_id();
        return if _player_on_stream($instance);
        $instance->detach_player(silent => 1);
        $attach_block{ $instance->client_id() } = Time::HiRes::time() + REATTACH_GRACE;
        my $status = _soloist_status($instance);
        $instance->send_action('pause')
            if $status eq 'playing' || $status eq 'buffering';
    };
    Slim::Control::Request::subscribe($newsong, [['playlist'], ['newsong']]);
    push @subscriptions, $newsong;
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
    my $managed = _installer()->installed_binary();
    my $preflight = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
        websocket_available => $websocket,
        ($managed ? (soloist_binary => $managed) : ()),
    );
    my $found = $preflight->{tools} || {};
    for my $required (qw(soloist pulseaudio parec ffmpeg)) {
        return (undef, "missing_$required") unless $found->{$required};
    }
    return ({ %$found }, undef);
}

sub _manager_fail {
    my ($code, $message) = @_;
    $code ||= 'managed_failed';
    my $repeated = $last_error && ($last_error->{code} || '') eq $code;
    $last_error = {
        code    => $code,
        message => _clean_message($message),
    };
    $log->warn("Soloist backend: $code - $last_error->{message}")
        if $log && !$repeated;
    return 0;
}

sub _item_summary {
    my ($item) = @_;
    return {} unless ref($item) eq 'HASH' && defined $item->{name};
    return {
        title  => $item->{name},
        artist => join(', ', grep { length($_) } map {
            ref($_) eq 'HASH' ? ($_->{name} || '') : ''
        } @{ $item->{creators} || [] }),
    };
}

sub _write_api_key {
    my ($key) = @_;
    my $base = baseDir();
    _secure_directory($base);
    my $path = apiKeyFile();
    my $tmp = "$path.new";
    unlink($tmp) if -e $tmp || -l $tmp;

    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or die "Unable to create API key file: $!";
    binmode($fh);
    my $written = syswrite($fh, $key);
    my $closed = close($fh);
    unless (defined $written && $written == length($key) && $closed) {
        unlink($tmp);
        die 'Unable to write API key file';
    }
    # rename() replaces a pre-existing api-key entry itself, including a
    # symlink, rather than writing through it.
    unless (chmod(0600, $tmp) && rename($tmp, $path)) {
        my $error = "$!";
        unlink($tmp);
        die "Unable to install API key file: $error";
    }
    return 1;
}

# Version line of the installed Soloist binary and, when it carries an ISO
# build date, the date the 90-day build lifetime ends.  Cached per binary
# file identity so a replaced binary is picked up immediately.
sub _binary_version {
    my ($path) = @_;
    my @stat = stat($path) or return ();
    # Release archives carry a fixed mtime, so include inode and ctime.
    my $cache_key = join(':', $path, @stat[0, 1, 7, 9, 10]);
    return %{ $version_cache{$cache_key} } if $version_cache{$cache_key};

    my ($output, $pid) = ('');
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(VERSION_TIMEOUT);
        $pid = open(my $fh, '-|', $path, '--version')
            or die "Unable to run soloist --version: $!";
        local $/;
        $output = <$fh>;
        close($fh);
        alarm(0);
        1;
    };
    alarm(0);
    unless ($ok) {
        if ($pid && kill(0, $pid)) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
        return ();
    }

    my ($line) = grep { /\S/ } split /\r?\n/, (defined $output ? $output : '');
    return () unless defined $line;
    $line = _clean_message($line);
    $line = substr($line, 0, 120);

    # Soloist prints e.g. "soloist 1.3.9.38 build 1792476110 (20261020)
    # (g440165f200) (linux/x86_64)": a build timestamp, its date, a commit and
    # the platform.  Show only the version and derive the 90-day expiry.
    my %build = (
        version => $line =~ /\A(soloist\s+\d[\w.+-]*)/ ? $1 : $line,
    );
    my $built;
    if ($line =~ /\bbuild\s+(\d{9,11})\b/) {
        $built = $1;
    }
    elsif ($output =~ /\b(20\d{2})-?(\d{2})-?(\d{2})\b/) {
        $built = eval { timegm(0, 0, 0, $3, $2 - 1, $1) };
    }
    if (defined $built) {
        my @date = gmtime($built);
        $build{build_date} = sprintf('%04d-%02d-%02d', $date[5] + 1900, $date[4] + 1, $date[3]);
        $build{expires_at} = $built + BUILD_LIFETIME_DAYS * 86_400;
    }
    %version_cache = ($cache_key => { %build });
    return %build;
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

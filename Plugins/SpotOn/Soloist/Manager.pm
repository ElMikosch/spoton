package Plugins::SpotOn::Soloist::Manager;

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use Scalar::Util qw(blessed);
use Time::HiRes ();

use constant START_POLL_INTERVAL  => 0.2;
use constant HEALTH_POLL_INTERVAL => 5;
use constant MAX_API_KEY_BYTES    => 1024;

my ($log, $prefs, $server_prefs);
my $runtime;
my $session;
my $stream_token;
my $stream_path;
my $player_id;
my $player_stream_url;
my $state = 'stopped';
my $last_error;
my $last_event_type;
my $last_update;

sub init {
    _ensure_lms();
    require Plugins::SpotOn::Soloist::StreamServer;
    Plugins::SpotOn::Soloist::StreamServer->init();
    return 1;
}

sub baseDir {
    _ensure_lms();
    return catdir($server_prefs->get('cachedir'), 'spoton', 'soloist-managed');
}

sub apiKeyFile {
    return catfile(baseDir(), 'api-key');
}

sub start {
    my ($class) = @_;
    _ensure_lms();

    return 1 if $state eq 'starting' || $state eq 'running';
    $class->stop() if $state eq 'failed';
    $last_error = undef;

    my $base = baseDir();
    my $directory_ready = eval {
        make_path($base, { mode => 0700 }) unless -e $base;
        my @stat = lstat($base);
        die 'Unable to inspect managed runtime directory' unless @stat;
        die 'Managed runtime directory must not be a symlink' if -l _;
        die 'Managed runtime path is not a directory' unless -d _;
        die 'Managed runtime directory has the wrong owner' unless $stat[4] == $>;
        chmod 0700, $base or die "Unable to protect managed runtime directory: $!";
        1;
    };
    return _fail('base_dir_failed', $@) unless $directory_ready;

    my ($api_key, $key_error) = _read_api_key(apiKeyFile());
    return _fail($key_error, 'Soloist API key file is unavailable') unless $api_key;

    require Plugins::SpotOn::Soloist::AudioPreflight;
    require Plugins::SpotOn::Soloist::Transport;
    my $websocket = Plugins::SpotOn::Soloist::Transport->websocket_available();
    my $preflight = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
        websocket_available => $websocket,
    );
    my $tools = $preflight->{tools} || {};
    for my $required (qw(soloist pulseaudio parec ffmpeg)) {
        return _fail("missing_$required", 'Required Soloist runtime tool is unavailable')
            unless $tools->{$required};
    }
    return _fail('lms_simplews_missing', 'LMS WebSocket client is unavailable')
        unless $websocket;

    require Plugins::SpotOn::Soloist::Runtime;
    my $runtime_error;
    my $created = eval {
        $runtime = Plugins::SpotOn::Soloist::Runtime->new(
            api_key           => $api_key,
            device_name       => 'SpotOn Soloist Managed Test',
            soloist_binary    => $tools->{soloist},
            pulseaudio_binary => $tools->{pulseaudio},
            parec_binary      => $tools->{parec},
            ffmpeg_binary     => $tools->{ffmpeg},
            runtime_dir       => catdir($base, 'runtime'),
            data_dir          => catdir($base, 'data'),
            cache_dir         => catdir($base, 'cache'),
            log_dir           => catdir($base, 'logs'),
            initial_volume    => 100,
            cache_size        => 100,
            verbose           => $prefs->get('diagnosticMode') ? 1 : 0,
        );
        my $started = $runtime->start() ? 1 : 0;
        $runtime_error = $runtime->last_error() unless $started;
        $started;
    };
    my $exception = $@;
    $api_key = undef;
    return _fail_runtime(
        $runtime_error,
        'runtime_start_failed',
        $exception || 'Managed runtime rejected start',
    ) unless $created;

    $state = 'starting';
    _schedule_poll(START_POLL_INTERVAL);
    return 1;
}

sub stop {
    _ensure_lms();
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_poll);

    if ($stream_token) {
        require Plugins::SpotOn::Soloist::StreamServer;
        eval { Plugins::SpotOn::Soloist::StreamServer->unregister_runtime($stream_token) };
    }
    eval { $session->stop() } if $session;
    eval { $runtime->stop() } if $runtime;

    undef $session;
    undef $runtime;
    undef $stream_token;
    undef $stream_path;
    undef $player_id;
    undef $player_stream_url;
    $state = 'stopped';
    return 1;
}

sub attachPlayer {
    my ($class, $client) = @_;
    _ensure_lms();

    return _command_fail('player_runtime_not_ready', 'Managed runtime is not running')
        unless $state eq 'running' && $stream_path;
    return _command_fail('player_required', 'An LMS player is required')
        unless blessed($client) && $client->can('id');

    if ($client->can('master')) {
        my $master = eval { $client->master() };
        $client = $master if $master;
    }
    my $id = eval { $client->id() };
    return _command_fail('player_invalid', 'Unable to identify LMS player')
        unless defined $id && !ref($id)
            && $id =~ /\A[0-9A-Za-z:._-]{1,128}\z/;

    require Slim::Utils::Network;
    my $host = Slim::Utils::Network::serverAddr();
    my $port = $server_prefs->get('httpport');
    return _command_fail('player_server_address', 'LMS server address is unavailable')
        unless defined $host && !ref($host) && length($host)
            && $host !~ /[\x00-\x20\x7f\/@]/;
    return _command_fail('player_server_port', 'LMS HTTP port is unavailable')
        unless defined $port && !ref($port) && $port =~ /\A\d+\z/
            && $port >= 1 && $port <= 65_535;

    $host = "[$host]" if $host =~ /:/ && $host !~ /\A\[.*\]\z/;
    my $url = "http://$host:$port$stream_path";

    require Slim::Control::Request;
    my $request_created = eval {
        my $request = Slim::Control::Request->new(
            $id,
            ['playlist', 'play', $url, 'SpotOn Soloist Managed Test'],
        );
        die 'Unable to create LMS player request' unless $request;
        $request->source(__PACKAGE__) if $request->can('source');
        $request->execute();
        1;
    };
    return _command_fail('player_play_failed', $@ || 'Unable to start LMS player')
        unless $request_created;

    $player_id = $id;
    $player_stream_url = $url;
    $last_error = undef
        if $last_error && ($last_error->{code} || '') =~ /\Aplayer_/;
    return 1;
}

sub detachPlayer {
    my ($class) = @_;
    _ensure_lms();
    return 1 unless $player_id;

    my $id = $player_id;
    undef $player_id;
    undef $player_stream_url;

    require Slim::Control::Request;
    my $request_created = eval {
        my $request = Slim::Control::Request->new($id, ['stop']);
        die 'Unable to create LMS player stop request' unless $request;
        $request->source(__PACKAGE__) if $request->can('source');
        $request->execute();
        1;
    };
    return _command_fail('player_stop_failed', $@ || 'Unable to stop LMS player')
        unless $request_created;

    $last_error = undef
        if $last_error && ($last_error->{code} || '') =~ /\Aplayer_/;
    return 1;
}

sub shutdown {
    my ($class) = @_;
    $class->stop();
    if ($INC{'Plugins/SpotOn/Soloist/StreamServer.pm'}) {
        Plugins::SpotOn::Soloist::StreamServer->shutdown();
    }
    return 1;
}

sub statusSnapshot {
    _ensure_lms();
    return {
        state         => $state,
        lastError     => $last_error,
        baseDir       => baseDir(),
        apiKeyFile    => apiKeyFile(),
        apiKeyReady   => _api_key_file_ready(apiKeyFile()),
        runtime       => $runtime ? $runtime->status_snapshot() : undef,
        session       => $session ? $session->snapshot() : undef,
        sessionStatus => $session ? $session->status() : 'idle',
        streamToken   => $stream_token,
        streamPath    => $stream_path,
        playerAttached => $player_id ? 1 : 0,
        playerId      => $player_id,
        playerStreamUrl => $player_stream_url,
        lastEventType => $last_event_type,
        lastUpdate    => $last_update,
    };
}

sub _poll {
    return unless $runtime && ($state eq 'starting' || $state eq 'running');

    my $runtime_state = $runtime->poll();
    if (!$runtime_state || $runtime_state eq 'failed') {
        _fail_runtime(
            $runtime->last_error(),
            'runtime_failed',
            'Managed runtime failed',
        );
        return;
    }

    if ($runtime_state eq 'running' && $state eq 'starting') {
        my $attached = eval { _attach_running_runtime(); 1 };
        unless ($attached) {
            _fail('runtime_attach_failed', $@);
            return;
        }
        $state = 'running';
    }

    if ($state eq 'running' && $session && !$session->connected()) {
        eval { $session->refresh() };
    }

    _schedule_poll($state eq 'starting'
        ? START_POLL_INTERVAL
        : HEALTH_POLL_INTERVAL);
}

sub _attach_running_runtime {
    require Plugins::SpotOn::Soloist::Session;
    require Plugins::SpotOn::Soloist::StreamServer;

    $stream_token = _random_token();
    $stream_path = Plugins::SpotOn::Soloist::StreamServer->register_runtime(
        $stream_token,
        sub { $runtime->new_stream_pipeline() },
    );

    $session = Plugins::SpotOn::Soloist::Session->new(
        data_dir => catdir(baseDir(), 'data'),
        on_update => sub {
            my ($event) = @_;
            $last_update = time();
            $last_event_type = $event->{event_type};
        },
        on_status => sub {
            my ($new_status) = @_;
            if ($new_status eq 'connected') {
                $last_error = undef
                    if $last_error && $last_error->{code} eq 'session_disconnected';
            }
            elsif ($state eq 'running' && $new_status eq 'disconnected') {
                $last_error = {
                    code    => 'session_disconnected',
                    message => 'Soloist WebSocket session disconnected',
                };
            }
        },
        on_error => sub {
            my ($code, $message) = @_;
            $last_error = {
                code    => "session_$code",
                message => _clean_message($message),
            };
        },
    );
    $session->start();
    return 1;
}

sub _schedule_poll {
    my ($delay) = @_;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_poll);
    Slim::Utils::Timers::setTimer(
        __PACKAGE__,
        Time::HiRes::time() + $delay,
        \&_poll,
    );
}

sub _fail {
    my ($code, $message) = @_;
    if ($INC{'Slim/Utils/Timers.pm'}) {
        Slim::Utils::Timers::killTimers(__PACKAGE__, \&_poll);
    }
    $last_error = {
        code    => $code,
        message => _clean_message($message),
    };

    if ($stream_token && $INC{'Plugins/SpotOn/Soloist/StreamServer.pm'}) {
        eval { Plugins::SpotOn::Soloist::StreamServer->unregister_runtime($stream_token) };
    }
    eval { $session->stop() } if $session;
    eval { $runtime->stop() } if $runtime;
    undef $session;
    undef $runtime;
    undef $stream_token;
    undef $stream_path;
    undef $player_id;
    undef $player_stream_url;
    $state = 'failed';
    return 0;
}

sub _command_fail {
    my ($code, $message) = @_;
    $last_error = {
        code    => $code,
        message => _clean_message($message),
    };
    return 0;
}

sub _fail_runtime {
    my ($runtime_error, $fallback_code, $fallback_message) = @_;
    $runtime_error = {} unless ref($runtime_error) eq 'HASH';

    my $code = $runtime_error->{code} || $fallback_code;
    $code = 'runtime_' . $code unless $code =~ /\Aruntime_/;
    my $message = $runtime_error->{message} || $fallback_message;
    return _fail($code, $message);
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

sub _random_token {
    open(my $fh, '<', '/dev/urandom') or die "Unable to open random source: $!";
    binmode($fh);
    my $bytes = '';
    while (length($bytes) < 12) {
        my $read = read($fh, my $chunk, 12 - length($bytes));
        die 'Unable to read random source' unless defined $read && $read > 0;
        $bytes .= $chunk;
    }
    close($fh);
    return unpack('H*', $bytes);
}

sub _clean_message {
    my ($message) = @_;
    $message = '' unless defined $message;
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

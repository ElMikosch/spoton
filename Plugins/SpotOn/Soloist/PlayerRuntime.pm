package Plugins::SpotOn::Soloist::PlayerRuntime;

use strict;
use warnings;

use Carp qw(croak);
use File::Spec::Functions qw(catdir);
use Scalar::Util qw(blessed weaken);
use Time::HiRes ();

use constant START_POLL_INTERVAL  => 0.2;
use constant HEALTH_POLL_INTERVAL => 5;

sub new {
    my ($class, %args) = @_;

    my $client_id = _required_text($args{client_id}, 'client_id');
    croak 'Soloist player runtime client_id is invalid'
        unless $client_id =~ /\A[0-9A-Za-z:._-]{1,128}\z/;
    croak 'Soloist player runtime tools are required'
        unless ref($args{tools}) eq 'HASH';

    return bless {
        client_id       => $client_id,
        device_name     => _required_text($args{device_name}, 'device_name'),
        base_dir        => _required_text($args{base_dir}, 'base_dir'),
        api_key         => _required_text($args{api_key}, 'api_key'),
        tools           => { %{ $args{tools} } },
        verbose         => $args{verbose} ? 1 : 0,
        on_update       => $args{on_update},
        on_status       => $args{on_status},
        on_error        => $args{on_error},
        stream_paths    => {},
        state           => 'stopped',
        metadata        => undef,
    }, $class;
}

sub start {
    my ($self) = @_;
    return 1 if $self->{state} eq 'starting' || $self->{state} eq 'running';
    $self->stop() if $self->{state} eq 'failed';

    my $tools = $self->{tools};
    require Plugins::SpotOn::Soloist::Runtime;
    my $runtime_error;
    my $created = eval {
        $self->{runtime} = Plugins::SpotOn::Soloist::Runtime->new(
            api_key           => $self->{api_key},
            device_name       => $self->{device_name},
            soloist_binary    => $tools->{soloist},
            pulseaudio_binary => $tools->{pulseaudio},
            parec_binary      => $tools->{parec},
            ffmpeg_binary     => $tools->{ffmpeg},
            runtime_dir       => catdir($self->{base_dir}, 'runtime'),
            data_dir          => catdir($self->{base_dir}, 'data'),
            cache_dir         => catdir($self->{base_dir}, 'cache'),
            log_dir           => catdir($self->{base_dir}, 'logs'),
            initial_volume    => 100,
            cache_size        => 100,
            verbose           => $self->{verbose},
        );
        my $started = $self->{runtime}->start() ? 1 : 0;
        $runtime_error = $self->{runtime}->last_error() unless $started;
        $started;
    };
    my $exception = $@;
    delete $self->{api_key};
    return $self->_fail_runtime(
        $runtime_error,
        'runtime_start_failed',
        $exception || 'Managed player runtime rejected start',
    ) unless $created;

    $self->{state} = 'starting';
    $self->_notify('on_status', 'starting', $self->status_snapshot());
    $self->_schedule_poll(START_POLL_INTERVAL);
    return 1;
}

sub stop {
    my ($self) = @_;
    if ($INC{'Slim/Utils/Timers.pm'}) {
        require Slim::Utils::Timers;
        Slim::Utils::Timers::killTimers($self, \&_poll_timer);
    }

    if ($self->{stream_token}
        && $INC{'Plugins/SpotOn/Soloist/StreamServer.pm'}) {
        eval {
            Plugins::SpotOn::Soloist::StreamServer->unregister_runtime(
                $self->{stream_token},
            );
        };
    }
    eval { $self->{session}->stop() } if $self->{session};
    eval { $self->{runtime}->stop() } if $self->{runtime};

    delete @$self{qw(
        session runtime stream_token stream_path player_id player_stream_url
        player_stream_format last_event_type last_update
    )};
    $self->{stream_paths} = {};
    $self->{state} = 'stopped';
    $self->_notify('on_status', 'stopped', $self->status_snapshot());
    return 1;
}

sub poll_now {
    my ($self) = @_;
    return unless $self->{runtime}
        && ($self->{state} eq 'starting' || $self->{state} eq 'running');

    my $runtime_state = $self->{runtime}->poll();
    if (!$runtime_state || $runtime_state eq 'failed') {
        $self->_fail_runtime(
            $self->{runtime}->last_error(),
            'runtime_failed',
            'Managed player runtime failed',
        );
        return;
    }

    if ($runtime_state eq 'running' && $self->{state} eq 'starting') {
        my $attached = eval { $self->_attach_running_runtime(); 1 };
        return $self->_fail('runtime_attach_failed', $@) unless $attached;
        $self->{state} = 'running';
        $self->_notify('on_status', 'running', $self->status_snapshot());
    }

    if ($self->{state} eq 'running'
        && $self->{session}
        && !$self->{session}->connected()) {
        eval { $self->{session}->refresh() };
    }

    $self->_schedule_poll(
        $self->{state} eq 'starting'
            ? START_POLL_INTERVAL
            : HEALTH_POLL_INTERVAL
    );
    return $self->{state};
}

sub attach_player {
    my ($self, $client, %args) = @_;
    my $format = defined $args{format} ? $args{format} : 'pcm';
    return $self->_command_fail(
        'player_format_invalid',
        'Player stream format must be flac or pcm',
    ) unless !ref($format) && $format =~ /\A(?:flac|pcm)\z/;
    return $self->_command_fail(
        'player_runtime_not_ready',
        'Managed player runtime is not running',
    ) unless $self->{state} eq 'running' && $self->{stream_paths}{$format};
    return $self->_command_fail('player_required', 'An LMS player is required')
        unless blessed($client) && $client->can('id');

    if ($client->can('master')) {
        my $master = eval { $client->master() };
        $client = $master if $master;
    }
    my $id = eval { $client->id() };
    return $self->_command_fail('player_invalid', 'Unable to identify LMS player')
        unless defined $id && !ref($id)
            && $id =~ /\A[0-9A-Za-z:._-]{1,128}\z/;
    return $self->_command_fail(
        'player_mismatch',
        'Managed player runtime belongs to a different LMS player',
    ) unless $id eq $self->{client_id};

    my $url;
    if ($format eq 'pcm') {
        my $token = $self->{stream_token};
        return $self->_command_fail(
            'player_stream_token_invalid',
            'Managed PCM stream token is unavailable',
        ) unless defined $token && $token =~ /\A[0-9a-f]{24}\z/;
        $url = "spoton://soloist-pcm:$token";
    }
    else {
        require Slim::Utils::Network;
        require Slim::Utils::Prefs;
        my $server_prefs = Slim::Utils::Prefs::preferences('server');
        my $host = Slim::Utils::Network::serverAddr();
        my $port = $server_prefs->get('httpport');
        return $self->_command_fail(
            'player_server_address',
            'LMS server address is unavailable',
        ) unless defined $host && !ref($host) && length($host)
            && $host !~ /[\x00-\x20\x7f\/@]/;
        return $self->_command_fail(
            'player_server_port',
            'LMS HTTP port is unavailable',
        ) unless defined $port && !ref($port) && $port =~ /\A\d+\z/
            && $port >= 1 && $port <= 65_535;
        $host = "[$host]" if $host =~ /:/ && $host !~ /\A\[.*\]\z/;
        $url = "http://$host:$port$self->{stream_paths}{$format}";
    }

    my $title = $args{title} || $self->{device_name};
    require Slim::Control::Request;
    my $request_created = eval {
        my $request = Slim::Control::Request->new(
            $id,
            ['playlist', 'play', $url, $title],
        );
        die 'Unable to create LMS player request' unless $request;
        $request->source('Plugins::SpotOn::Soloist::Manager')
            if $request->can('source');
        $request->execute();
        1;
    };
    return $self->_command_fail(
        'player_play_failed',
        $@ || 'Unable to start LMS player',
    ) unless $request_created;

    $self->{player_id} = $id;
    $self->{player_stream_url} = $url;
    $self->{player_stream_format} = $format;
    delete $self->{last_error}
        if $self->{last_error}
            && ($self->{last_error}{code} || '') =~ /\Aplayer_/;
    return 1;
}

sub detach_player {
    my ($self, %args) = @_;
    return 1 unless $self->{player_id};
    my $id = delete $self->{player_id};
    delete @$self{qw(player_stream_url player_stream_format)};
    return 1 if $args{silent};

    require Slim::Control::Request;
    my $created = eval {
        my $request = Slim::Control::Request->new($id, ['stop']);
        die 'Unable to create LMS player stop request' unless $request;
        $request->source('Plugins::SpotOn::Soloist::Manager')
            if $request->can('source');
        $request->execute();
        1;
    };
    return $self->_command_fail(
        'player_stop_failed',
        $@ || 'Unable to stop LMS player',
    ) unless $created;
    return 1;
}

sub send_action {
    my ($self, $action, %args) = @_;
    return 0 unless $self->{session} && $self->{session}->connected();
    return $self->{session}->send_action($action, %args) ? 1 : 0;
}

sub resolve_stream_path {
    my ($self, $token, $format) = @_;
    $format = 'pcm' unless defined $format;
    return unless $self->{state} eq 'running';
    return unless defined $token && defined $self->{stream_token}
        && $token eq $self->{stream_token};
    return unless defined $format && $format =~ /\A(?:flac|pcm)\z/;
    return $self->{stream_paths}{$format};
}

sub new_stream_pipeline {
    my ($self, $token, $format) = @_;
    $format = 'pcm' unless defined $format;
    return unless $self->{state} eq 'running' && $self->{runtime};
    return unless defined $token && defined $self->{stream_token}
        && $token eq $self->{stream_token};
    return unless defined $format && $format =~ /\A(?:flac|pcm)\z/;
    my $pipeline = eval { $self->{runtime}->new_stream_pipeline($format) };
    return blessed($pipeline) ? $pipeline : undef;
}

sub set_metadata {
    my ($self, $metadata) = @_;
    $self->{metadata} = ref($metadata) eq 'HASH' ? { %$metadata } : undef;
    return 1;
}

sub metadata {
    my ($self) = @_;
    return $self->{metadata} ? { %{ $self->{metadata} } } : undef;
}

sub session_snapshot {
    my ($self) = @_;
    return $self->{session} ? $self->{session}->snapshot() : undef;
}

sub is_active {
    my ($self) = @_;
    my $snapshot = $self->session_snapshot() || {};
    my $playback = $snapshot->{playback} || {};
    return $playback->{is_active} ? 1 : 0;
}

sub status_snapshot {
    my ($self) = @_;
    return {
        state              => $self->{state},
        clientId           => $self->{client_id},
        deviceName         => $self->{device_name},
        lastError          => $self->{last_error},
        runtime            => $self->{runtime}
            ? $self->{runtime}->status_snapshot()
            : undef,
        session            => $self->session_snapshot(),
        sessionStatus      => $self->{session}
            ? $self->{session}->status()
            : 'idle',
        streamToken        => $self->{stream_token},
        streamPath         => $self->{stream_path},
        streamPaths        => { %{ $self->{stream_paths} || {} } },
        playerAttached     => $self->{player_id} ? 1 : 0,
        playerId           => $self->{player_id},
        playerStreamUrl    => $self->{player_stream_url},
        playerStreamFormat => $self->{player_stream_format},
        lastEventType      => $self->{last_event_type},
        lastUpdate         => $self->{last_update},
        metadata           => $self->metadata(),
    };
}

sub client_id { $_[0]{client_id} }
sub device_name { $_[0]{device_name} }
sub state { $_[0]{state} }
sub stream_token { $_[0]{stream_token} }
sub player_id { $_[0]{player_id} }

sub _attach_running_runtime {
    my ($self) = @_;
    require Plugins::SpotOn::Soloist::Session;
    require Plugins::SpotOn::Soloist::StreamServer;

    my $token = _random_token();
    $self->{stream_token} = $token;
    $self->{stream_path} =
        Plugins::SpotOn::Soloist::StreamServer->register_runtime(
            $token,
            sub { $self->{runtime}->new_stream_pipeline('flac') },
        );
    my $pcm_path =
        Plugins::SpotOn::Soloist::StreamServer->register_runtime_format(
            $token,
            'pcm',
            sub { $self->{runtime}->new_stream_pipeline('pcm') },
        );
    $self->{stream_paths} = {
        flac => $self->{stream_path},
        pcm  => $pcm_path,
    };

    my $weak = $self;
    weaken($weak);
    $self->{session} = Plugins::SpotOn::Soloist::Session->new(
        data_dir => catdir($self->{base_dir}, 'data'),
        on_update => sub {
            return unless $weak;
            my ($event, $snapshot) = @_;
            $weak->{last_update} = time();
            $weak->{last_event_type} = $event->{event_type};
            $weak->_notify('on_update', $weak, $event, $snapshot);
        },
        on_status => sub {
            return unless $weak;
            my ($status, $snapshot) = @_;
            if ($status eq 'connected') {
                delete $weak->{last_error}
                    if $weak->{last_error}
                        && ($weak->{last_error}{code} || '') =~ /\Asession_/;
            }
            elsif ($weak->{state} eq 'running' && $status eq 'disconnected') {
                $weak->{last_error} = {
                    code    => 'session_disconnected',
                    message => 'Soloist WebSocket session disconnected',
                };
            }
            $weak->_notify('on_status', $status, $weak->status_snapshot());
        },
        on_error => sub {
            return unless $weak;
            my ($code, $message) = @_;
            $weak->{last_error} = {
                code    => "session_$code",
                message => _clean_message($message),
            };
            $weak->_notify(
                'on_error',
                $weak,
                "session_$code",
                _clean_message($message),
            );
        },
    );
    $self->{session}->start();
    return 1;
}

sub _schedule_poll {
    my ($self, $delay) = @_;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers($self, \&_poll_timer);
    Slim::Utils::Timers::setTimer(
        $self,
        Time::HiRes::time() + $delay,
        \&_poll_timer,
    );
}

sub _poll_timer {
    my ($self) = @_;
    $self->poll_now();
}

sub _fail_runtime {
    my ($self, $runtime_error, $fallback_code, $fallback_message) = @_;
    $runtime_error = {} unless ref($runtime_error) eq 'HASH';
    my $code = $runtime_error->{code} || $fallback_code;
    $code = 'runtime_' . $code unless $code =~ /\Aruntime_/;
    return $self->_fail(
        $code,
        $runtime_error->{message} || $fallback_message,
    );
}

sub _fail {
    my ($self, $code, $message) = @_;
    $self->{last_error} = {
        code    => $code,
        message => _clean_message($message),
    };
    if ($self->{stream_token}
        && $INC{'Plugins/SpotOn/Soloist/StreamServer.pm'}) {
        eval {
            Plugins::SpotOn::Soloist::StreamServer->unregister_runtime(
                $self->{stream_token},
            );
        };
    }
    eval { $self->{session}->stop() } if $self->{session};
    eval { $self->{runtime}->stop() } if $self->{runtime};
    delete @$self{qw(session runtime stream_token stream_path player_id player_stream_url player_stream_format)};
    $self->{stream_paths} = {};
    $self->{state} = 'failed';
    $self->_notify('on_error', $self, $code, $self->{last_error}{message});
    return 0;
}

sub _command_fail {
    my ($self, $code, $message) = @_;
    $self->{last_error} = {
        code    => $code,
        message => _clean_message($message),
    };
    return 0;
}

sub _notify {
    my ($self, $name, @args) = @_;
    my $callback = $self->{$name};
    return unless ref($callback) eq 'CODE';
    eval { $callback->(@args) };
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

sub _required_text {
    my ($value, $name) = @_;
    croak "Soloist player runtime $name is required"
        unless defined $value && !ref($value) && length($value);
    croak "Soloist player runtime $name contains a control character"
        if $value =~ /[\x00-\x1f\x7f]/;
    return $value;
}

sub _clean_message {
    my ($message) = @_;
    $message = '' unless defined $message;
    $message = "$message";
    $message =~ s/[\x00-\x1f\x7f]+/ /g;
    $message =~ s/^\s+|\s+$//g;
    return $message;
}

1;

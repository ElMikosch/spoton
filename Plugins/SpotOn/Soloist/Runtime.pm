package Plugins::SpotOn::Soloist::Runtime;

use strict;
use warnings;

use Carp qw(croak);
use Fcntl qw(O_APPEND O_CREAT O_EXCL O_WRONLY);
use File::Path qw(make_path);
use File::Spec;
use Time::HiRes ();

use Plugins::SpotOn::Soloist::Endpoint qw(discover_endpoint);
use Plugins::SpotOn::Soloist::ProcessSpec qw(build_process_spec);
use Plugins::SpotOn::Soloist::PulseBridgeSpec qw(build_server_spec);

use constant COOKIE_BYTES          => 256;
use constant PULSE_START_TIMEOUT   => 10;
use constant SOLOIST_START_TIMEOUT => 15;

my %SUPPORTED_OPTIONS = map { $_ => 1 } qw(
    api_key
    cache_dir
    cache_size
    clock
    data_dir
    device_name
    endpoint_discover
    initial_volume
    log_dir
    pulseaudio_binary
    pulse_start_timeout
    random_bytes
    runtime_dir
    sink_name
    socket_ready
    soloist_binary
    soloist_start_timeout
    spawn
    verbose
);

sub new {
    my ($class, %args) = @_;

    for my $key (keys %args) {
        croak "Unsupported Soloist runtime option: $key"
            unless $SUPPORTED_OPTIONS{$key};
    }

    my $self = bless {
        api_key              => _required_text($args{api_key}, 'api_key'),
        cache_dir            => _absolute_path($args{cache_dir}, 'cache_dir'),
        cache_size           => exists $args{cache_size} ? $args{cache_size} : 100,
        clock                => $args{clock} || sub { Time::HiRes::time() },
        data_dir             => _absolute_path($args{data_dir}, 'data_dir'),
        device_name          => _required_text($args{device_name}, 'device_name'),
        endpoint_discover    => $args{endpoint_discover} || \&discover_endpoint,
        initial_volume       => exists $args{initial_volume} ? $args{initial_volume} : 100,
        log_dir              => _absolute_path($args{log_dir}, 'log_dir'),
        pulseaudio_binary    => _required_text($args{pulseaudio_binary}, 'pulseaudio_binary'),
        pulse_start_timeout  => _positive_number(
            $args{pulse_start_timeout},
            PULSE_START_TIMEOUT,
            'pulse_start_timeout',
        ),
        random_bytes         => $args{random_bytes} || \&_random_bytes,
        runtime_dir          => _absolute_path($args{runtime_dir}, 'runtime_dir'),
        sink_name            => defined $args{sink_name} ? $args{sink_name} : 'spoton_soloist',
        socket_ready         => $args{socket_ready} || sub { -S $_[0] ? 1 : 0 },
        soloist_binary       => _required_text($args{soloist_binary}, 'soloist_binary'),
        soloist_start_timeout => _positive_number(
            $args{soloist_start_timeout},
            SOLOIST_START_TIMEOUT,
            'soloist_start_timeout',
        ),
        spawn                => $args{spawn} || \&_spawn_process,
        verbose              => $args{verbose} ? 1 : 0,
        state                => 'stopped',
    }, $class;

    $self->{socket_path} = File::Spec->catfile($self->{runtime_dir}, 'native');
    croak 'Soloist Pulse socket path is too long'
        if length($self->{socket_path}) > 100;

    return $self;
}

sub start {
    my ($self) = @_;

    return 1 if $self->{state} eq 'starting_pulse'
        || $self->{state} eq 'starting_soloist'
        || $self->{state} eq 'running';
    return 0 unless $self->{state} eq 'stopped';

    $self->{last_error} = undef;
    my $prepared = eval { $self->_prepare_layout(); 1 };
    return $self->_fail('runtime_prepare_failed', $@) unless $prepared;

    my $pulse_spec = eval {
        build_server_spec(
            binary      => $self->{pulseaudio_binary},
            socket_path => $self->{socket_path},
            sink_name   => $self->{sink_name},
        );
    };
    return $self->_fail('pulse_spec_failed', $@) unless $pulse_spec;

    my $soloist_spec = eval {
        build_process_spec(
            binary         => $self->{soloist_binary},
            device_name    => $self->{device_name},
            api_key        => $self->{api_key},
            data_dir       => $self->{data_dir},
            cache_dir      => $self->{cache_dir},
            cache_size     => $self->{cache_size},
            initial_volume => $self->{initial_volume},
            pulse_server   => $pulse_spec->{env}{PULSE_SERVER},
            pulse_cookie   => $pulse_spec->{env}{PULSE_COOKIE},
            verbose        => $self->{verbose},
        );
    };
    return $self->_fail('soloist_spec_failed', $@) unless $soloist_spec;

    $self->{pulse_spec}   = $pulse_spec;
    $self->{soloist_spec} = $soloist_spec;
    my $logs_ready = eval {
        $self->{pulse_log_fh} = $self->_open_log('pulse.log');
        $self->{soloist_log_fh} = $self->_open_log('soloist.log');
        1;
    };
    return $self->_fail('log_open_failed', $@) unless $logs_ready;

    my $pulse = eval {
        $self->{spawn}->(
            'pulse',
            $pulse_spec,
            $self->{pulse_log_fh},
            $self->{pulse_log_fh},
        );
    };
    return $self->_fail('pulse_spawn_failed', $@)
        unless $pulse;

    $self->{pulse_proc} = $pulse;
    $self->{state} = 'starting_pulse';
    $self->{deadline} = $self->{clock}->() + $self->{pulse_start_timeout};
    return 1;
}

sub poll {
    my ($self) = @_;

    if ($self->{state} eq 'starting_pulse') {
        return $self->_fail('pulse_exited', 'PulseAudio exited before readiness')
            unless _process_alive($self->{pulse_proc});

        if ($self->{socket_ready}->($self->{socket_path})) {
            my $soloist = eval {
                $self->{spawn}->(
                    'soloist',
                    $self->{soloist_spec},
                    $self->{soloist_log_fh},
                    $self->{soloist_log_fh},
                );
            };
            return $self->_fail('soloist_spawn_failed', $@)
                unless $soloist;

            $self->{soloist_proc} = $soloist;
            $self->{state} = 'starting_soloist';
            $self->{deadline} = $self->{clock}->() + $self->{soloist_start_timeout};
            return $self->{state};
        }

        return $self->_fail('pulse_start_timeout', 'PulseAudio socket was not created')
            if $self->{clock}->() >= $self->{deadline};
        return $self->{state};
    }

    if ($self->{state} eq 'starting_soloist') {
        return $self->_fail('pulse_exited', 'PulseAudio exited during Soloist startup')
            unless _process_alive($self->{pulse_proc});
        return $self->_fail('soloist_exited', 'Soloist exited before endpoint readiness')
            unless _process_alive($self->{soloist_proc});

        my ($endpoint, $error) = $self->{endpoint_discover}->($self->{data_dir});
        if ($endpoint) {
            $self->{endpoint} = $endpoint;
            $self->{state} = 'running';
            delete $self->{deadline};
            return $self->{state};
        }

        if (defined $error && $error ne 'not_ready') {
            return $self->_fail('endpoint_' . $error, 'Unsafe or invalid Soloist endpoint');
        }
        return $self->_fail('soloist_start_timeout', 'Soloist endpoint was not created')
            if $self->{clock}->() >= $self->{deadline};
        return $self->{state};
    }

    if ($self->{state} eq 'running') {
        return $self->_fail('pulse_exited', 'PulseAudio exited while running')
            unless _process_alive($self->{pulse_proc});
        return $self->_fail('soloist_exited', 'Soloist exited while running')
            unless _process_alive($self->{soloist_proc});
    }

    return $self->{state};
}

sub stop {
    my ($self) = @_;

    _terminate($self->{soloist_proc});
    _terminate($self->{pulse_proc});
    delete @$self{qw(soloist_proc pulse_proc endpoint deadline)};
    $self->_close_logs();
    $self->{state} = 'stopped';
    return 1;
}

sub state {
    return $_[0]{state};
}

sub endpoint {
    return $_[0]{endpoint};
}

sub last_error {
    return $_[0]{last_error};
}

sub status_snapshot {
    my ($self) = @_;

    return {
        state       => $self->{state},
        lastError   => $self->{last_error},
        endpoint    => $self->{endpoint},
        socketPath  => $self->{socket_path},
        dataDir     => $self->{data_dir},
        cacheDir    => $self->{cache_dir},
        pulsePid    => _process_pid($self->{pulse_proc}),
        soloistPid  => _process_pid($self->{soloist_proc}),
        pulseArgv   => $self->{pulse_spec} ? [ @{ $self->{pulse_spec}{argv} } ] : undef,
        soloistArgv => $self->{soloist_spec}
            ? [ @{ $self->{soloist_spec}{redacted_argv} } ]
            : undef,
    };
}

sub _prepare_layout {
    my ($self) = @_;

    for my $directory (
        $self->{runtime_dir},
        File::Spec->catdir($self->{runtime_dir}, 'config'),
        File::Spec->catdir($self->{runtime_dir}, 'config', 'pulse'),
        $self->{data_dir},
        $self->{cache_dir},
        $self->{log_dir},
    ) {
        _secure_directory($directory);
    }

    my $cookie = File::Spec->catfile(
        $self->{runtime_dir},
        'config',
        'pulse',
        'cookie',
    );
    _secure_cookie($cookie, $self->{random_bytes});
    return 1;
}

sub _open_log {
    my ($self, $name) = @_;
    my $path = File::Spec->catfile($self->{log_dir}, $name);

    if (-e $path || -l $path) {
        my @stat = lstat($path);
        croak 'Unable to inspect Soloist runtime log' unless @stat;
        croak 'Soloist runtime log must not be a symlink' if -l _;
        croak 'Soloist runtime log is not a regular file' unless -f _;
        croak 'Soloist runtime log has the wrong owner' unless $stat[4] == $>;
    }

    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_APPEND, 0600)
        or croak "Unable to open Soloist runtime log: $!";
    chmod 0600, $path or croak "Unable to protect Soloist runtime log: $!";
    return $fh;
}

sub _close_logs {
    my ($self) = @_;
    close(delete $self->{pulse_log_fh}) if $self->{pulse_log_fh};
    close(delete $self->{soloist_log_fh}) if $self->{soloist_log_fh};
}

sub _fail {
    my ($self, $code, $message) = @_;
    $message = '' unless defined $message;
    $message =~ s/[\x00-\x1f\x7f]+/ /g;
    $message =~ s/^\s+|\s+$//g;

    _terminate($self->{soloist_proc});
    _terminate($self->{pulse_proc});
    delete @$self{qw(soloist_proc pulse_proc endpoint deadline)};
    $self->_close_logs();
    $self->{last_error} = {
        code    => $code,
        message => $message,
    };
    $self->{state} = 'failed';
    return 0;
}

sub _secure_directory {
    my ($path) = @_;

    make_path($path, { mode => 0700 }) unless -e $path;
    my @stat = lstat($path);
    croak "Unable to inspect Soloist runtime directory: $path" unless @stat;
    croak "Soloist runtime directory must not be a symlink: $path" if -l _;
    croak "Soloist runtime path is not a directory: $path" unless -d _;
    croak "Soloist runtime directory has the wrong owner: $path"
        unless $stat[4] == $>;
    chmod 0700, $path or croak "Unable to protect Soloist runtime directory: $path";
    return 1;
}

sub _secure_cookie {
    my ($path, $random_bytes) = @_;

    if (-e $path || -l $path) {
        my @stat = lstat($path);
        croak 'Unable to inspect PulseAudio cookie' unless @stat;
        croak 'PulseAudio cookie must not be a symlink' if -l _;
        croak 'PulseAudio cookie is not a regular file' unless -f _;
        croak 'PulseAudio cookie has the wrong owner' unless $stat[4] == $>;
        croak 'PulseAudio cookie has an invalid size'
            unless $stat[7] == COOKIE_BYTES;
        chmod 0600, $path or croak 'Unable to protect PulseAudio cookie';
        return 1;
    }

    my $bytes = $random_bytes->(COOKIE_BYTES);
    croak 'PulseAudio cookie generator returned invalid data'
        unless defined $bytes && !ref($bytes) && length($bytes) == COOKIE_BYTES;

    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or croak "Unable to create PulseAudio cookie: $!";
    binmode($fh);
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $written = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
        if (!defined $written || $written == 0) {
            close($fh);
            unlink($path);
            croak "Unable to write PulseAudio cookie: $!";
        }
        $offset += $written;
    }
    close($fh) or do {
        unlink($path);
        croak "Unable to close PulseAudio cookie: $!";
    };
    chmod 0600, $path or croak 'Unable to protect PulseAudio cookie';
    return 1;
}

sub _random_bytes {
    my ($length) = @_;
    open(my $fh, '<', '/dev/urandom')
        or croak "Unable to open system random source: $!";
    binmode($fh);
    my $bytes = '';
    while (length($bytes) < $length) {
        my $read = read($fh, my $chunk, $length - length($bytes));
        croak 'Unable to read system random source'
            unless defined $read && $read > 0;
        $bytes .= $chunk;
    }
    close($fh);
    return $bytes;
}

sub _spawn_process {
    my ($kind, $spec, $stdout_fh, $stderr_fh) = @_;
    require Proc::Background;

    local %ENV = (%ENV, %{ $spec->{env} || {} });
    return Proc::Background->new(
        {
            die_upon_destroy => 1,
            stdout           => $stdout_fh,
            stderr           => $stderr_fh,
        },
        @{ $spec->{argv} },
    );
}

sub _process_alive {
    my ($process) = @_;
    return $process && eval { $process->alive() } ? 1 : 0;
}

sub _process_pid {
    my ($process) = @_;
    return undef unless $process;
    my $pid = eval { $process->pid() };
    return defined $pid && $pid =~ /\A\d+\z/ ? 0 + $pid : undef;
}

sub _terminate {
    my ($process) = @_;
    return unless $process && eval { $process->alive() };
    eval { $process->die() };
}

sub _required_text {
    my ($value, $name) = @_;
    croak "Soloist runtime $name is required"
        unless defined $value && !ref($value) && length($value);
    croak "Soloist runtime $name contains a control character"
        if $value =~ /[\x00-\x1f\x7f]/;
    return $value;
}

sub _absolute_path {
    my ($value, $name) = @_;
    $value = _required_text($value, $name);
    croak "Soloist runtime $name must be absolute"
        unless File::Spec->file_name_is_absolute($value);
    return $value;
}

sub _positive_number {
    my ($value, $default, $name) = @_;
    $value = $default unless defined $value;
    croak "Soloist runtime $name must be a positive number"
        unless !ref($value) && $value =~ /\A(?:\d+(?:\.\d+)?|\.\d+)\z/
            && $value > 0;
    return 0 + $value;
}

1;

package Plugins::SpotOn::Soloist::StreamPipeline;

use strict;
use warnings;

use Carp qw(croak);
use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use POSIX ();

my %SUPPORTED_OPTIONS = map { $_ => 1 } qw(
    capture_spec
    encoder_spec
    log_fh
);

sub new {
    my ($class, %args) = @_;

    for my $key (keys %args) {
        croak "Unsupported Soloist stream pipeline option: $key"
            unless $SUPPORTED_OPTIONS{$key};
    }

    return bless {
        capture_spec => _process_spec($args{capture_spec}, 'capture'),
        encoder_spec => _process_spec($args{encoder_spec}, 'encoder'),
        log_fh       => $args{log_fh},
        state        => 'stopped',
        bytes_read   => 0,
    }, $class;
}

sub start {
    my ($self) = @_;

    return 1 if $self->{state} eq 'running';
    return 0 unless $self->{state} eq 'stopped';

    pipe(my $capture_read, my $capture_write)
        or return $self->_fail('capture_pipe_failed', "$!");
    pipe(my $encoded_read, my $encoded_write)
        or do {
            close($capture_read);
            close($capture_write);
            return $self->_fail('encoder_pipe_failed', "$!");
        };

    binmode($_) for ($capture_read, $capture_write, $encoded_read, $encoded_write);

    my $capture_pid = _fork_exec(
        spec      => $self->{capture_spec},
        stdin_fh  => undef,
        stdout_fh => $capture_write,
        log_fh    => $self->{log_fh},
        close_fhs => [$capture_read, $capture_write, $encoded_read, $encoded_write],
    );
    if (!$capture_pid) {
        close($_) for ($capture_read, $capture_write, $encoded_read, $encoded_write);
        return $self->_fail('capture_spawn_failed', "$!");
    }

    my $encoder_pid = _fork_exec(
        spec      => $self->{encoder_spec},
        stdin_fh  => $capture_read,
        stdout_fh => $encoded_write,
        log_fh    => $self->{log_fh},
        close_fhs => [$capture_read, $capture_write, $encoded_read, $encoded_write],
    );
    if (!$encoder_pid) {
        close($_) for ($capture_read, $capture_write, $encoded_read, $encoded_write);
        _terminate_and_reap($capture_pid);
        return $self->_fail('encoder_spawn_failed', "$!");
    }

    close($capture_read);
    close($capture_write);
    close($encoded_write);

    my $flags = fcntl($encoded_read, F_GETFL, 0);
    if (!defined $flags || !fcntl($encoded_read, F_SETFL, $flags | O_NONBLOCK)) {
        close($encoded_read);
        _terminate_and_reap($capture_pid);
        _terminate_and_reap($encoder_pid);
        return $self->_fail('nonblocking_failed', "$!");
    }

    $self->{capture_pid} = $capture_pid;
    $self->{encoder_pid} = $encoder_pid;
    $self->{output_fh} = $encoded_read;
    $self->{state} = 'running';
    $self->{last_error} = undef;
    return 1;
}

sub read_chunk {
    my ($self, $maximum) = @_;
    return (undef, 'not_running') unless $self->{state} eq 'running';

    $maximum = 32 * 1024 unless defined $maximum;
    croak 'Soloist stream read size must be between 1 and 1048576'
        unless !ref($maximum) && $maximum =~ /\A\d+\z/
            && $maximum >= 1 && $maximum <= 1024 * 1024;

    my $length = sysread($self->{output_fh}, my $buffer, $maximum);
    if (!defined $length) {
        return (undef, 'would_block') if $! == EAGAIN || $! == EWOULDBLOCK;
        return $self->_read_failure("$!");
    }

    if ($length == 0) {
        $self->{state} = 'eof';
        return ('', 'eof');
    }

    $self->{bytes_read} += $length;
    return ($buffer, 'data');
}

sub output_fh {
    return $_[0]{output_fh};
}

sub state {
    return $_[0]{state};
}

sub alive {
    my ($self) = @_;
    return 0 unless $self->{state} eq 'running';

    my $capture = _reap($self, 'capture_pid');
    my $encoder = _reap($self, 'encoder_pid');
    return $capture && $encoder ? 1 : 0;
}

sub stop {
    my ($self) = @_;

    close(delete $self->{output_fh}) if $self->{output_fh};
    _terminate_and_reap(delete $self->{capture_pid});
    _terminate_and_reap(delete $self->{encoder_pid});
    $self->{state} = 'stopped';
    return 1;
}

sub status_snapshot {
    my ($self) = @_;
    return {
        state      => $self->{state},
        capturePid => $self->{capture_pid},
        encoderPid => $self->{encoder_pid},
        bytesRead  => $self->{bytes_read},
        lastError  => $self->{last_error},
    };
}

sub DESTROY {
    my ($self) = @_;
    $self->stop() if $self->{state} ne 'stopped';
}

sub _read_failure {
    my ($self, $message) = @_;
    $self->{last_error} = {
        code    => 'read_failed',
        message => _clean_message($message),
    };
    $self->{state} = 'failed';
    return (undef, 'read_failed');
}

sub _fail {
    my ($self, $code, $message) = @_;
    $self->{last_error} = {
        code    => $code,
        message => _clean_message($message),
    };
    $self->{state} = 'failed';
    return 0;
}

sub _fork_exec {
    my (%args) = @_;
    my $pid = fork();
    return undef unless defined $pid;
    return $pid if $pid;

    my $spec = $args{spec};
    my $null_fh;

    my $ok = eval {
        untie *STDERR if tied(*STDERR);

        if ($args{stdin_fh}) {
            open(STDIN, '<&', $args{stdin_fh})
                or die "Unable to connect child stdin: $!";
        }
        else {
            open($null_fh, '<', '/dev/null')
                or die "Unable to open null input: $!";
            open(STDIN, '<&', $null_fh)
                or die "Unable to connect null input: $!";
        }

        open(STDOUT, '>&', $args{stdout_fh})
            or die "Unable to connect child stdout: $!";

        if ($args{log_fh}) {
            open(STDERR, '>&', $args{log_fh})
                or die "Unable to connect child stderr: $!";
        }
        else {
            open(my $null_error, '>', '/dev/null')
                or die "Unable to open null error output: $!";
            open(STDERR, '>&', $null_error)
                or die "Unable to connect null error output: $!";
        }

        for my $fh (@{ $args{close_fhs} || [] }) {
            close($fh) if defined fileno($fh) && fileno($fh) > 2;
        }
        close($null_fh) if $null_fh && defined fileno($null_fh) && fileno($null_fh) > 2;

        local %ENV = (%ENV, %{ $spec->{env} || {} });
        my @argv = @{ $spec->{argv} };
        exec { $argv[0] } @argv;
        die "Unable to execute child: $!";
    };

    print STDERR "SpotOn Soloist stream child failed before exec\n" unless $ok;
    POSIX::_exit(127);
}

sub _process_spec {
    my ($spec, $name) = @_;
    croak "Soloist stream $name spec is required"
        unless ref($spec) eq 'HASH';
    croak "Soloist stream $name argv is required"
        unless ref($spec->{argv}) eq 'ARRAY' && @{ $spec->{argv} };

    for my $argument (@{ $spec->{argv} }) {
        croak "Soloist stream $name argv contains invalid data"
            unless defined $argument && !ref($argument)
                && $argument !~ /[\x00\r\n]/;
    }
    croak "Soloist stream $name environment must be a hash"
        if exists $spec->{env} && ref($spec->{env}) ne 'HASH';
    for my $key (keys %{ $spec->{env} || {} }) {
        my $value = $spec->{env}{$key};
        croak "Soloist stream $name environment contains invalid data"
            unless $key =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
                && defined $value && !ref($value)
                && $value !~ /[\x00\r\n]/;
    }

    my %copy = %$spec;
    $copy{argv} = [ @{ $spec->{argv} } ];
    $copy{env} = { %{ $spec->{env} || {} } };
    return \%copy;
}

sub _reap {
    my ($self, $key) = @_;
    my $pid = $self->{$key} || return 0;
    my $result = waitpid($pid, POSIX::WNOHANG());
    if ($result == $pid || $result == -1) {
        delete $self->{$key};
        return 0;
    }
    return kill(0, $pid) ? 1 : 0;
}

sub _terminate_and_reap {
    my ($pid) = @_;
    return unless $pid && $pid =~ /\A\d+\z/ && $pid > 1;
    kill 'TERM', $pid;
    my $result = waitpid($pid, POSIX::WNOHANG());
    if ($result == 0) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
}

sub _clean_message {
    my ($message) = @_;
    $message = '' unless defined $message;
    $message =~ s/[\x00-\x1f\x7f]+/ /g;
    $message =~ s/^\s+|\s+$//g;
    return $message;
}

1;

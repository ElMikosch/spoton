package Plugins::SpotOn::Soloist::Transport;

use strict;
use warnings;

use JSON::PP ();

use Plugins::SpotOn::Soloist::Endpoint qw(is_loopback_address);
use Plugins::SpotOn::Soloist::Protocol qw(build_commands normalize_event);

sub new {
    my ($class, %args) = @_;

    return bless {
        ws_factory       => $args{ws_factory},
        json_encode      => $args{json_encode} || \&JSON::PP::encode_json,
        json_decode      => $args{json_decode} || \&JSON::PP::decode_json,
        on_connected     => $args{on_connected},
        on_disconnected  => $args{on_disconnected},
        on_event         => $args{on_event},
        on_error         => $args{on_error},
        state            => 'idle',
        socket           => undef,
        url              => undef,
        handshake_done   => 0,
        listening        => 0,
        intentional_stop => 0,
        last_error       => undef,
    }, $class;
}

sub set_callbacks {
    my ($self, %callbacks) = @_;

    for my $name (qw(on_connected on_disconnected on_event on_error)) {
        $self->{$name} = $callbacks{$name} if exists $callbacks{$name};
    }
    return $self;
}

sub connect {
    my ($self, $url) = @_;

    unless (_is_loopback_url($url)) {
        $self->_fail('unsafe_endpoint', 'Soloist WebSocket endpoint must be loopback-only');
        return 0;
    }

    $self->close() if $self->{socket};

    $self->{state}            = 'connecting';
    $self->{url}              = $url;
    $self->{handshake_done}   = 0;
    $self->{listening}        = 0;
    $self->{intentional_stop} = 0;
    $self->{last_error}       = undef;

    my $factory = $self->{ws_factory} || \&_default_ws_factory;
    my $connect_error;
    my $socket;

    my $ok = eval {
        $socket = $factory->(
            $url,
            sub {
                $self->{handshake_done} = 1;
                $self->_finish_connect() if $self->{socket};
            },
            sub {
                my ($message) = @_;
                $connect_error = defined $message && length($message)
                    ? $message
                    : 'WebSocket connection failed';
            },
        );
        1;
    };

    if (!$ok || $connect_error || !$socket) {
        my $message = !$ok ? ($@ || 'WebSocket constructor failed')
                    : $connect_error || 'WebSocket constructor returned no socket';
        $self->_close_socket($socket);
        $self->_fail('connect_failed', $message);
        return 0;
    }

    $self->{socket} = $socket;
    $self->_finish_connect() if $self->{handshake_done};
    return 1;
}

sub send_action {
    my ($self, $action, %args) = @_;

    unless ($self->connected) {
        $self->_fail('not_connected', 'Cannot send Soloist command while disconnected');
        return 0;
    }

    my $messages = eval { build_commands($action, %args) };
    if ($@ || !$messages) {
        $self->_fail('invalid_command', $@ || 'Unable to build Soloist command');
        return 0;
    }

    for my $message (@$messages) {
        my $frame = eval { $self->{json_encode}->($message) };
        if ($@ || !defined $frame) {
            $self->_fail('encode_failed', $@ || 'Unable to encode Soloist command');
            return 0;
        }

        my $sent = eval {
            $self->{socket}->send($frame);
            1;
        };
        if (!$sent) {
            $self->_fail('send_failed', $@ || 'Unable to send Soloist command');
            return 0;
        }
    }

    return 1;
}

sub close {
    my ($self) = @_;

    $self->{intentional_stop} = 1;
    my $socket = delete $self->{socket};
    $self->_close_socket($socket);

    $self->{state}          = 'closed';
    $self->{listening}      = 0;
    $self->{handshake_done} = 0;
    return 1;
}

sub connected {
    my ($self) = @_;
    return $self->{state} eq 'connected' ? 1 : 0;
}

sub state {
    my ($self) = @_;
    return $self->{state};
}

sub url {
    my ($self) = @_;
    return $self->{url};
}

sub last_error {
    my ($self) = @_;
    return $self->{last_error};
}

sub websocket_available {
    return eval { require Slim::Networking::SimpleWS; 1 } ? 1 : 0;
}

sub _finish_connect {
    my ($self) = @_;
    return if $self->{listening};
    return unless $self->{socket} && $self->{handshake_done};

    $self->{state}     = 'connected';
    $self->{listening} = 1;

    my $ok = eval {
        $self->{socket}->listenAsync(
            sub { $self->_receive_frame(@_) },
            sub { $self->_read_failed(@_) },
        );
        1;
    };

    if (!$ok) {
        $self->{listening} = 0;
        $self->_fail('listen_failed', $@ || 'Unable to listen on Soloist WebSocket');
        return;
    }

    $self->_callback('on_connected', $self->{url});
}

sub _receive_frame {
    my ($self, $frame) = @_;

    my $decoded = eval { $self->{json_decode}->($frame) };
    if ($@ || ref($decoded) ne 'HASH') {
        $self->_fail('invalid_json', $@ || 'Soloist event is not a JSON object');
        return;
    }

    my $event = eval { normalize_event($decoded) };
    if ($@ || !$event) {
        $self->_fail('invalid_event', $@ || 'Unable to normalize Soloist event');
        return;
    }

    $self->_callback('on_event', $event, $decoded);
}

sub _read_failed {
    my ($self, @details) = @_;
    return if $self->{intentional_stop};

    my $message = @details && defined $details[0] && length($details[0])
        ? $details[0]
        : 'Soloist WebSocket disconnected';

    my $socket = delete $self->{socket};
    $self->_close_socket($socket);
    $self->{state}     = 'disconnected';
    $self->{listening} = 0;
    $self->{last_error} = {
        code    => 'disconnected',
        message => $message,
    };

    $self->_callback('on_disconnected', $message);
}

sub _fail {
    my ($self, $code, $message) = @_;

    $message = "$message";
    $message =~ s{\s+\z}{};

    $self->{last_error} = {
        code    => $code,
        message => $message,
    };
    $self->{state} = 'error' if $code eq 'connect_failed' || $code eq 'listen_failed';
    $self->_callback('on_error', $code, $message);
}

sub _callback {
    my ($self, $name, @args) = @_;
    my $callback = $self->{$name};
    return unless ref($callback) eq 'CODE';
    eval { $callback->(@args) };
}

sub _close_socket {
    my ($self, $socket) = @_;
    return unless $socket;

    eval { $socket->endListenAsync() if $socket->can('endListenAsync') };
    eval { $socket->close() };
}

sub _default_ws_factory {
    my ($url, $connected, $failed) = @_;
    require Slim::Networking::SimpleWS;
    return Slim::Networking::SimpleWS->new($url, $connected, $failed);
}

sub _is_loopback_url {
    my ($url) = @_;
    return 0 unless defined $url && !ref($url);

    my ($address, $port);
    if ($url =~ m{\Aws://(127(?:\.\d{1,3}){3}):(\d+)\z}) {
        ($address, $port) = ($1, $2);
    }
    elsif ($url =~ m{\Aws://\[(::1)\]:(\d+)\z}) {
        ($address, $port) = ($1, $2);
    }
    else {
        return 0;
    }

    return 0 unless is_loopback_address($address);
    return $port >= 1 && $port <= 65_535 ? 1 : 0;
}

1;

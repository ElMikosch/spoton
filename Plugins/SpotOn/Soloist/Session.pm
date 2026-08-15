package Plugins::SpotOn::Soloist::Session;

use strict;
use warnings;

use Plugins::SpotOn::Soloist::Endpoint qw(discover_endpoint);
use Plugins::SpotOn::Soloist::Transport;

sub new {
    my ($class, %args) = @_;

    return bless {
        data_dir          => $args{data_dir},
        transport         => $args{transport},
        transport_factory => $args{transport_factory},
        on_update         => $args{on_update},
        on_status         => $args{on_status},
        on_error          => $args{on_error},
        endpoint          => undef,
        status            => 'idle',
        state             => {
            connection => 'idle',
            auth       => undef,
            playback   => {},
            queue      => { previous => [], upcoming => [] },
            last_error => undef,
        },
    }, $class;
}

sub start {
    my ($self) = @_;

    my ($endpoint, $error) = discover_endpoint($self->{data_dir});
    unless ($endpoint) {
        my $status = $error eq 'not_ready' ? 'waiting_endpoint' : 'error';
        $self->_set_status($status);
        $self->_record_error('endpoint_' . $error, "Soloist endpoint discovery failed: $error")
            unless $error eq 'not_ready';
        return 0;
    }

    $self->{endpoint} = $endpoint;
    my $transport = $self->{transport} || $self->_create_transport();
    return 0 unless $transport;

    $self->{transport} = $transport;
    $transport->set_callbacks(
        on_connected => sub { $self->_transport_connected(@_) },
        on_disconnected => sub { $self->_transport_disconnected(@_) },
        on_event => sub { $self->_transport_event(@_) },
        on_error => sub { $self->_transport_error(@_) },
    );

    $self->_set_status('connecting');
    my $started = $transport->connect($endpoint->{url});
    $self->_set_status('error') unless $started;
    return $started ? 1 : 0;
}

sub refresh {
    my ($self) = @_;
    return 1 if $self->connected;
    return $self->start();
}

sub stop {
    my ($self) = @_;
    $self->{transport}->close() if $self->{transport};
    $self->_set_status('stopped');
    return 1;
}

sub send_action {
    my ($self, $action, %args) = @_;
    return 0 unless $self->{transport};
    return $self->{transport}->send_action($action, %args);
}

sub connected {
    my ($self) = @_;
    return $self->{transport} && $self->{transport}->connected ? 1 : 0;
}

sub status {
    my ($self) = @_;
    return $self->{status};
}

sub endpoint {
    my ($self) = @_;
    return _clone($self->{endpoint});
}

sub snapshot {
    my ($self) = @_;
    return _clone($self->{state});
}

sub _create_transport {
    my ($self) = @_;

    if (ref($self->{transport_factory}) eq 'CODE') {
        my $transport = eval { $self->{transport_factory}->() };
        if ($@ || !$transport) {
            $self->_record_error(
                'transport_factory_failed',
                $@ || 'Soloist transport factory returned no transport',
            );
            $self->_set_status('error');
            return;
        }
        return $transport;
    }

    return Plugins::SpotOn::Soloist::Transport->new();
}

sub _transport_connected {
    my ($self) = @_;
    $self->_set_status('connected');

    # Soloist sends auth_state on connect by contract. Query it as well so a
    # reconnect has a deterministic first request even if a future daemon
    # changes snapshot timing.
    $self->{transport}->send_action('auth_state');
}

sub _transport_disconnected {
    my ($self, $message) = @_;
    $self->_set_status('disconnected');
    $self->{state}{last_error} = {
        code    => 'disconnected',
        message => $message,
    };
}

sub _transport_error {
    my ($self, $code, $message) = @_;
    $self->_record_error($code, $message);
    $self->_set_status('error')
        if $code eq 'connect_failed' || $code eq 'listen_failed';
}

sub _transport_event {
    my ($self, $event) = @_;

    $self->_apply_event($event);
    $self->_callback('on_update', $event, $self->snapshot());
}

sub _apply_event {
    my ($self, $event) = @_;
    my $kind = $event->{kind} || 'unknown';

    if ($kind eq 'auth') {
        $self->{state}{auth} = {
            logged_in   => $event->{logged_in},
            is_active   => $event->{is_active},
            device_name => $event->{device_name},
        };
        return;
    }

    if ($kind eq 'state') {
        $self->{state}{playback} = {
            status            => $event->{status},
            item              => _clone($event->{item}),
            context           => _clone($event->{context}),
            position          => _clone($event->{position}),
            volume            => $event->{volume},
            is_active         => $event->{is_active},
            options           => _clone($event->{options}),
            available_actions => _clone($event->{available_actions}),
        };
        return;
    }

    if ($kind eq 'item') {
        $self->{state}{playback}{item} = _clone($event->{item});
        return;
    }

    if ($kind eq 'playback') {
        $self->{state}{playback}{status} = $event->{status};
        return;
    }

    if ($kind eq 'volume') {
        $self->{state}{playback}{volume} = $event->{volume};
        return;
    }

    if ($kind eq 'device') {
        $self->{state}{playback}{is_active} = $event->{is_active};
        $self->{state}{device_name} = $event->{device_name};
        return;
    }

    if ($kind eq 'context') {
        $self->{state}{playback}{context} = _clone($event->{context});
        return;
    }

    if ($kind eq 'options') {
        $self->{state}{playback}{options} = _clone($event->{options});
        return;
    }

    if ($kind eq 'position') {
        $self->{state}{playback}{position} = _clone($event->{position});
        return;
    }

    if ($kind eq 'queue') {
        $self->{state}{queue} = {
            previous => _clone($event->{previous}) || [],
            upcoming => _clone($event->{upcoming}) || [],
        };
        return;
    }

    if ($kind eq 'command_result') {
        $self->{state}{last_command} = $event->{command};
        return;
    }

    if ($kind eq 'error') {
        $self->{state}{last_error} = {
            code    => 'soloist_error',
            message => $event->{message},
        };
        return;
    }

    $self->{state}{last_event} = _clone($event);
}

sub _set_status {
    my ($self, $status) = @_;
    return if $self->{status} eq $status;

    $self->{status} = $status;
    $self->{state}{connection} = $status;
    $self->_callback('on_status', $status, $self->snapshot());
}

sub _record_error {
    my ($self, $code, $message) = @_;
    $message = "$message";
    $message =~ s{\s+\z}{};

    $self->{state}{last_error} = {
        code    => $code,
        message => $message,
    };
    $self->_callback('on_error', $code, $message);
}

sub _callback {
    my ($self, $name, @args) = @_;
    my $callback = $self->{$name};
    return unless ref($callback) eq 'CODE';
    eval { $callback->(@args) };
}

sub _clone {
    my ($value) = @_;
    return undef unless defined $value;

    return { map { $_ => _clone($value->{$_}) } keys %$value }
        if ref($value) eq 'HASH';
    return [ map { _clone($_) } @$value ]
        if ref($value) eq 'ARRAY';
    return $value;
}

1;

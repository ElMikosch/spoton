package Plugins::SpotOn::Soloist::Protocol;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use JSON::PP ();

our @EXPORT_OK = qw(build_commands normalize_entity normalize_event);

# Keep the Soloist wire protocol behind a small, LMS-independent boundary.
# The future WebSocket transport can encode build_commands()' return values
# directly and feed decoded events through normalize_event().

my %SIMPLE_COMMANDS = (
    auth_state => 'get_auth_state',
    state      => 'get_state',
    pause      => 'pause',
    next       => 'skip_next',
    previous   => 'skip_prev',
    activate   => 'activate',
    deactivate => 'deactivate',
);

sub build_commands {
    my ($action, %args) = @_;

    croak 'Soloist action is required'
        unless defined $action && !ref($action) && length($action);

    if (my $command = $SIMPLE_COMMANDS{$action}) {
        return [ _command($command) ];
    }

    if ($action eq 'play') {
        my $message = _command('play');
        if (exists $args{uri}) {
            $message->{uri} = _spotify_uri($args{uri}, 'play uri');
        }
        return [ $message ];
    }

    if ($action eq 'queue') {
        my $message = _command('get_queue');
        if (exists $args{limit}) {
            $message->{limit} = _integer($args{limit}, 'queue limit', 0, undef);
        }
        return [ $message ];
    }

    if ($action eq 'seek') {
        return [
            _command(
                'seek',
                position_ms => _integer($args{position_ms}, 'seek position_ms', 0, undef),
            )
        ];
    }

    if ($action eq 'volume') {
        return [
            _command(
                'set_volume',
                volume => _integer($args{volume}, 'volume', 0, 100),
            )
        ];
    }

    if ($action eq 'shuffle') {
        return [
            _command(
                'set_shuffle',
                enabled => _json_boolean($args{enabled}, 'shuffle enabled'),
            )
        ];
    }

    if ($action eq 'repeat') {
        my $mode = $args{mode};
        croak 'repeat mode must be off, context, or track'
            unless defined $mode && !ref($mode)
                && ($mode eq 'off' || $mode eq 'context' || $mode eq 'track');

        # Soloist exposes two repeat switches. Ordering is part of Spotify's
        # documented protocol and avoids a transient mixed repeat state.
        if ($mode eq 'track') {
            return [
                _command('set_repeat_context', enabled => JSON::PP::false()),
                _command('set_repeat_track',   enabled => JSON::PP::true()),
            ];
        }

        return [
            _command('set_repeat_track',   enabled => JSON::PP::false()),
            _command(
                'set_repeat_context',
                enabled => $mode eq 'context' ? JSON::PP::true() : JSON::PP::false(),
            ),
        ];
    }

    if ($action eq 'add_to_queue') {
        my $uri = _spotify_uri($args{uri}, 'queue uri');
        croak 'queue uri must be a Spotify track URI'
            unless $uri =~ m{\Aspotify:track:[^:]+\z};
        return [ _command('add_to_queue', uri => $uri) ];
    }

    croak "Unsupported Soloist action: $action";
}

sub normalize_event {
    my ($event) = @_;

    croak 'Soloist event must be a hash reference'
        unless ref($event) eq 'HASH';

    my $type = $event->{type};
    croak 'Soloist event type is required'
        unless defined $type && !ref($type) && length($type);

    if ($type eq 'auth_state') {
        return {
            kind        => 'auth',
            event_type  => $type,
            logged_in   => _plain_boolean($event->{logged_in}),
            is_active   => _plain_boolean($event->{is_active}),
            device_name => $event->{device_name},
        };
    }

    if ($type eq 'playback_state') {
        return {
            kind              => 'state',
            event_type        => $type,
            status            => $event->{status},
            item              => normalize_entity($event->{item}),
            context           => normalize_entity($event->{context}),
            position          => _normalize_position($event->{position}),
            volume            => $event->{volume},
            is_active         => _plain_boolean($event->{is_active}),
            options           => _normalize_options($event->{options}),
            available_actions => _clone($event->{available_actions}),
        };
    }

    if ($type eq 'track_changed') {
        return {
            kind       => 'item',
            event_type => $type,
            item       => normalize_entity($event->{item}),
        };
    }

    if ($type eq 'playback_changed') {
        return {
            kind       => 'playback',
            event_type => $type,
            status     => $event->{status},
        };
    }

    if ($type eq 'volume_changed') {
        return {
            kind       => 'volume',
            event_type => $type,
            volume     => $event->{volume},
        };
    }

    if ($type eq 'device_changed') {
        return {
            kind        => 'device',
            event_type  => $type,
            is_active   => _plain_boolean($event->{is_active}),
            device_name => $event->{device_name},
        };
    }

    if ($type eq 'context_changed') {
        return {
            kind       => 'context',
            event_type => $type,
            context    => normalize_entity($event->{context}),
        };
    }

    if ($type eq 'options_changed') {
        return {
            kind       => 'options',
            event_type => $type,
            options    => _normalize_options($event->{options}),
        };
    }

    if ($type eq 'position_sync') {
        return {
            kind       => 'position',
            event_type => $type,
            position   => _normalize_position($event->{position}),
        };
    }

    if ($type eq 'queue_changed') {
        return {
            kind       => 'queue',
            event_type => $type,
            previous   => _normalize_queue($event->{previous}),
            upcoming   => _normalize_queue($event->{upcoming}),
        };
    }

    if ($type eq 'command_result') {
        return {
            kind       => 'command_result',
            event_type => $type,
            command    => $event->{command},
        };
    }

    if ($type eq 'error') {
        return {
            kind       => 'error',
            event_type => $type,
            message    => $event->{message},
        };
    }

    # Do not discard future Soloist events. The adapter can log or inspect the
    # copied payload while older SpotOn versions continue operating.
    return {
        kind       => 'unknown',
        event_type => $type,
        payload    => _clone($event),
    };
}

sub normalize_entity {
    my ($entity) = @_;
    return undef unless ref($entity) eq 'HASH';

    my $decorations = ref($entity->{decorations}) eq 'HASH'
        ? $entity->{decorations}
        : {};
    my $identity = ref($decorations->{identity}) eq 'HASH'
        ? $decorations->{identity}
        : {};
    my $visual = ref($decorations->{visual_identity}) eq 'HASH'
        ? $decorations->{visual_identity}
        : {};
    my $playback = ref($decorations->{playback}) eq 'HASH'
        ? $decorations->{playback}
        : {};

    my @covers;
    if (ref($visual->{cover}) eq 'ARRAY') {
        @covers = map {
            ref($_) eq 'HASH'
                ? { url => $_->{url}, size => $_->{size} }
                : ()
        } @{ $visual->{cover} };
    }

    my @creators;
    if (ref($decorations->{creators}) eq 'ARRAY') {
        @creators = map {
            ref($_) eq 'HASH' ? _normalize_related_entity($_->{entity}) : ()
        } @{ $decorations->{creators} };
    }

    my $parent;
    if (ref($decorations->{parent}) eq 'HASH') {
        $parent = _normalize_related_entity($decorations->{parent}{entity});
    }

    return {
        uri             => $entity->{uri},
        entity_type     => $entity->{entity_type},
        name            => $identity->{name},
        duration_ms     => $playback->{duration_ms},
        content_ratings => ref($playback->{content_ratings}) eq 'ARRAY'
            ? [ @{ $playback->{content_ratings} } ]
            : [],
        covers  => \@covers,
        parent  => $parent,
        creators => \@creators,
    };
}

sub _command {
    my ($command, %fields) = @_;
    return {
        type    => 'command',
        command => $command,
        %fields,
    };
}

sub _integer {
    my ($value, $name, $minimum, $maximum) = @_;
    croak "$name is required"
        unless defined $value;
    croak "$name must be an integer"
        if ref($value) || $value !~ m{\A\d+\z};

    my $number = 0 + $value;
    croak "$name must be at least $minimum"
        if defined $minimum && $number < $minimum;
    croak "$name must be at most $maximum"
        if defined $maximum && $number > $maximum;
    return $number;
}

sub _json_boolean {
    my ($value, $name) = @_;
    croak "$name is required"
        unless defined $value;
    croak "$name must be 0 or 1"
        if ref($value) || ($value ne '0' && $value ne '1');
    return $value ? JSON::PP::true() : JSON::PP::false();
}

sub _plain_boolean {
    my ($value) = @_;
    return undef unless defined $value;
    return $value ? 1 : 0;
}

sub _spotify_uri {
    my ($value, $name) = @_;
    croak "$name is required"
        unless defined $value && !ref($value) && length($value);
    croak "$name must be a Spotify URI"
        unless $value =~ m{\Aspotify:[^:]+:.+\z};
    return $value;
}

sub _normalize_related_entity {
    my ($entity) = @_;
    return undef unless ref($entity) eq 'HASH';

    my $decorations = ref($entity->{decorations}) eq 'HASH'
        ? $entity->{decorations}
        : {};
    my $identity = ref($decorations->{identity}) eq 'HASH'
        ? $decorations->{identity}
        : {};

    return {
        uri         => $entity->{uri},
        entity_type => $entity->{entity_type},
        name        => $identity->{name},
    };
}

sub _normalize_position {
    my ($position) = @_;
    return undef unless ref($position) eq 'HASH';

    return {
        position_ms => $position->{position_ms},
        timestamp_ms => $position->{timestamp_ms},
        speed        => $position->{speed},
    };
}

sub _normalize_options {
    my ($options) = @_;
    return undef unless ref($options) eq 'HASH';

    return {
        shuffle       => _plain_boolean($options->{shuffle}),
        repeat        => $options->{repeat},
        playback_speed => $options->{playback_speed},
        modes         => _clone($options->{modes}),
    };
}

sub _normalize_queue {
    my ($entries) = @_;
    return [] unless ref($entries) eq 'ARRAY';

    return [
        map {
            {
                uid    => $_->{uid},
                source => $_->{source},
                item   => normalize_entity($_->{item}),
            }
        } grep { ref($_) eq 'HASH' } @$entries
    ];
}

sub _clone {
    my ($value) = @_;

    return { map { $_ => _clone($value->{$_}) } keys %$value }
        if ref($value) eq 'HASH';
    return [ map { _clone($_) } @$value ]
        if ref($value) eq 'ARRAY';
    return $value;
}

1;

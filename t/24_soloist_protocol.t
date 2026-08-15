#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Protocol qw(
    build_commands
    normalize_entity
    normalize_event
);

sub dies_like {
    my ($code, $pattern, $name) = @_;
    my $error = eval { $code->(); 1 } ? '' : $@;
    like($error, $pattern, $name);
}

is_deeply(
    build_commands('play'),
    [{ type => 'command', command => 'play' }],
    'play without URI resumes playback',
);

is_deeply(
    build_commands('play', uri => 'spotify:playlist:abc123'),
    [{ type => 'command', command => 'play', uri => 'spotify:playlist:abc123' }],
    'play accepts a playable context URI',
);

is_deeply(
    build_commands('next'),
    [{ type => 'command', command => 'skip_next' }],
    'LMS next maps to Soloist skip_next',
);

is_deeply(
    build_commands('previous'),
    [{ type => 'command', command => 'skip_prev' }],
    'LMS previous maps to Soloist skip_prev',
);

is_deeply(
    build_commands('seek', position_ms => 30_000),
    [{ type => 'command', command => 'seek', position_ms => 30_000 }],
    'seek preserves millisecond position',
);

is_deeply(
    build_commands('volume', volume => 65),
    [{ type => 'command', command => 'set_volume', volume => 65 }],
    'volume maps to set_volume',
);

is_deeply(
    build_commands('shuffle', enabled => 0),
    [{
        type    => 'command',
        command => 'set_shuffle',
        enabled => JSON::PP::false(),
    }],
    'shuffle uses a JSON boolean',
);

is_deeply(
    [ map { $_->{command} } @{ build_commands('repeat', mode => 'context') } ],
    [qw(set_repeat_track set_repeat_context)],
    'context repeat disables track repeat before enabling context repeat',
);

is_deeply(
    build_commands('repeat', mode => 'track'),
    [
        {
            type    => 'command',
            command => 'set_repeat_context',
            enabled => JSON::PP::false(),
        },
        {
            type    => 'command',
            command => 'set_repeat_track',
            enabled => JSON::PP::true(),
        },
    ],
    'track repeat uses Spotify documented command order and booleans',
);

is_deeply(
    build_commands('queue', limit => 10),
    [{ type => 'command', command => 'get_queue', limit => 10 }],
    'queue query supports a non-negative limit',
);

is_deeply(
    build_commands('add_to_queue', uri => 'spotify:track:abc123'),
    [{ type => 'command', command => 'add_to_queue', uri => 'spotify:track:abc123' }],
    'add_to_queue accepts track URI',
);

dies_like(
    sub { build_commands('volume', volume => 101) },
    qr/volume must be at most 100/,
    'volume above 100 is rejected',
);

dies_like(
    sub { build_commands('add_to_queue', uri => 'spotify:album:abc123') },
    qr/queue uri must be a Spotify track URI/,
    'queue rejects non-track URI',
);

dies_like(
    sub { build_commands('repeat', mode => 'all') },
    qr/repeat mode must be off, context, or track/,
    'unknown repeat mode is rejected',
);

my $state_event = JSON::PP::decode_json(<<'JSON');
{
  "type": "playback_state",
  "status": "playing",
  "item": {
    "uri": "spotify:track:track1",
    "entity_type": "track",
    "decorations": {
      "identity": { "name": "My Song" },
      "visual_identity": {
        "cover": [{ "url": "https://i.scdn.co/image/cover", "size": "large" }]
      },
      "parent": {
        "entity": {
          "uri": "spotify:album:album1",
          "entity_type": "album",
          "decorations": { "identity": { "name": "Album Name" } }
        }
      },
      "creators": [{
        "entity": {
          "uri": "spotify:artist:artist1",
          "entity_type": "artist",
          "decorations": { "identity": { "name": "Artist Name" } }
        }
      }],
      "playback": { "duration_ms": 210000, "content_ratings": ["explicit"] }
    }
  },
  "context": {
    "uri": "spotify:playlist:list1",
    "entity_type": "playlist",
    "decorations": { "identity": { "name": "My Playlist" } }
  },
  "position": { "position_ms": 45000, "timestamp_ms": 1747654321000, "speed": 1.0 },
  "volume": 65,
  "is_active": true,
  "options": { "shuffle": false, "repeat": "off", "playback_speed": 1.0, "modes": {} },
  "available_actions": { "pause": {}, "seek_forward": { "step_ms": 15000 } }
}
JSON

my $state = normalize_event($state_event);
is($state->{kind}, 'state', 'playback_state becomes a normalized state event');
is($state->{status}, 'playing', 'state retains playback status');
is($state->{item}{uri}, 'spotify:track:track1', 'state retains item URI');
is($state->{item}{name}, 'My Song', 'entity display name is normalized');
is($state->{item}{duration_ms}, 210_000, 'entity duration is normalized');
is_deeply($state->{item}{content_ratings}, ['explicit'], 'content ratings are retained');
is($state->{item}{covers}[0]{url}, 'https://i.scdn.co/image/cover', 'cover image is normalized');
is($state->{item}{parent}{name}, 'Album Name', 'parent entity is normalized');
is($state->{item}{creators}[0]{name}, 'Artist Name', 'creator entity is normalized');
is($state->{context}{uri}, 'spotify:playlist:list1', 'context entity is normalized');
is($state->{position}{position_ms}, 45_000, 'position anchor is normalized');
is($state->{position}{speed}, 1, 'position speed is normalized');
is($state->{volume}, 65, 'state retains volume');
is($state->{is_active}, 1, 'state normalizes active flag');
is($state->{options}{shuffle}, 0, 'state normalizes shuffle flag');
is($state->{available_actions}{seek_forward}{step_ms}, 15_000, 'action parameters are retained');

is_deeply(
    normalize_event({
        type     => 'position_sync',
        position => { position_ms => 99, timestamp_ms => 1234, speed => 0 },
    }),
    {
        kind       => 'position',
        event_type => 'position_sync',
        position   => { position_ms => 99, timestamp_ms => 1234, speed => 0 },
    },
    'position_sync becomes a normalized position anchor',
);

my $queue = normalize_event({
    type     => 'queue_changed',
    previous => [],
    upcoming => [{
        uid    => 'queue-1',
        source => 'queue',
        item   => {
            uri         => 'spotify:track:next1',
            entity_type => 'track',
            decorations => { identity => { name => 'Next Song' } },
        },
    }],
});
is($queue->{kind}, 'queue', 'queue_changed becomes a normalized queue event');
is($queue->{upcoming}[0]{source}, 'queue', 'queue source is retained');
is($queue->{upcoming}[0]{item}{name}, 'Next Song', 'queue item entity is normalized');

is_deeply(
    normalize_event({ type => 'command_result', command => 'pause' }),
    {
        kind       => 'command_result',
        event_type => 'command_result',
        command    => 'pause',
    },
    'command acknowledgement is normalized',
);

my $unknown_source = { type => 'future_event', nested => { value => 1 } };
my $unknown = normalize_event($unknown_source);
is($unknown->{kind}, 'unknown', 'future event types remain observable');
$unknown_source->{nested}{value} = 2;
is($unknown->{payload}{nested}{value}, 1, 'unknown event payload is copied');

dies_like(
    sub { normalize_event([]) },
    qr/Soloist event must be a hash reference/,
    'malformed event is rejected',
);

done_testing();

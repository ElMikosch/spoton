package Plugins::SpotOn::DontStopTheMusic;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Time::HiRes;

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Schema;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# init()
# Registers SpotOn as a DSTM provider.
# Called from Plugin.pm::initPlugin() when DontStopTheMusic plugin is enabled.
sub init {
    Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
        'PLUGIN_SPOTON_RECOMMENDATIONS',
        \&dontStopTheMusic
    );
}

# dontStopTheMusic($client, $cb)
# DSTM handler called by LMS when the playlist ends.
# $client  — Slim::Player::Client object
# $cb      — callback: $cb->($client, [$uri, ...]) with results, or $cb->($client) if no results
sub dontStopTheMusic {
    my ($client, $cb) = @_;

    my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 3);

    # Only proceed if we have tracks to seed from (not radio, not empty queue)
    if (!$seedTracks || !ref $seedTracks || !scalar @$seedTracks) {
        $cb->($client);
        return;
    }

    main::INFOLOG && $log->info("SpotOn DSTM: Auto-mixing Spotify tracks from current playlist");

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';
    unless ($accountId) {
        main::INFOLOG && $log->info("SpotOn DSTM: no active account, skipping");
        $cb->($client);
        return;
    }

    require Plugins::SpotOn::API::Client;

    my @searchData;
    my $seedData = {
        limit => 25,
    };

    # Classify each seed track:
    # - Negative ID: RemoteTrack — look up real URL via Slim::Schema
    # - Spotify track URI found: add directly to seed_tracks
    # - Non-Spotify with artist+title: queue for search-based matching
    # Also track the first available artist name for the search fallback (T-06-07).
    foreach my $track (@$seedTracks) {
        # RemoteTrack: negative numeric ID — resolve to actual URL
        if ($track->{id} && $track->{id} =~ /^-\d+$/) {
            my $trackObj = Slim::Schema->find('Track', $track->{id});
            if ($trackObj && $trackObj->url) {
                $track->{id} = $trackObj->url;
            }
        }

        if ($track->{id} && $track->{id} =~ /track:([a-z0-9]+)/i) {
            $seedData->{seed_tracks} ||= [];
            push @{$seedData->{seed_tracks}}, $1;
        }
        elsif ($track->{artist} && $track->{title}) {
            push @searchData, [$track->{artist}, $track->{title}];
        }

        # Store first artist name as fallback seed for _searchFallback
        $seedData->{_firstArtistName} ||= $track->{artist} if $track->{artist};
    }

    # Limit seed_tracks to max 3 (reduced from 5 to lower API call burst)
    if ($seedData->{seed_tracks} && scalar @{$seedData->{seed_tracks}} > 3) {
        splice @{$seedData->{seed_tracks}}, 3;
    }

    if (@searchData) {
        _searchForSeeds($client, $accountId, \@searchData, $seedData, $cb);
    }
    else {
        my $seedArtist = $seedData->{_firstArtistName};
        if ($seedArtist) {
            _searchFallback($client, $accountId, $seedArtist, $cb);
        }
        else {
            main::INFOLOG && $log->info("SpotOn DSTM: no artist seed available, skipping");
            $cb->($client);
        }
    }
}

# _searchForSeeds($client, $accountId, $searchDataRef, $seedData, $cb)
# Iterates non-Spotify seed entries sequentially with 200ms stagger between calls
# to prevent API burst that triggers 429 under single-Client-ID PKCE architecture.
# After all seeds processed, proceeds to _searchFallback for recommendations.
sub _searchForSeeds {
    my ($client, $accountId, $searchDataRef, $seedData, $cb) = @_;

    my @items = @$searchDataRef;

    my $done = sub {
        if ($seedData->{seed_tracks} && scalar @{$seedData->{seed_tracks}} > 3) {
            splice @{$seedData->{seed_tracks}}, 3;
        }
        if ($seedData->{seed_artists} && scalar @{$seedData->{seed_artists}} > 3) {
            splice @{$seedData->{seed_artists}}, 3;
        }
        my $seedArtist = $seedData->{_firstArtistName};
        if ($seedArtist) {
            _searchFallback($client, $accountId, $seedArtist, $cb);
        }
        else {
            main::INFOLOG && $log->info("SpotOn DSTM: no artist seed available after search, skipping");
            $cb->($client);
        }
    };

    _searchNextSeed($client, $accountId, \@items, 0, $seedData, $done);
}

# _searchNextSeed($client, $accountId, $itemsRef, $idx, $seedData, $done)
# Processes one seed at a time, scheduling the next with a 200ms delay.
# Prevents API burst by spreading calls across ~200ms intervals.
use constant DSTM_SEARCH_STAGGER_MS => 0.2;

sub _searchNextSeed {
    my ($client, $accountId, $itemsRef, $idx, $seedData, $done) = @_;

    if ($idx >= scalar @$itemsRef) {
        $done->();
        return;
    }

    my ($artist, $title) = @{$itemsRef->[$idx]};

    Plugins::SpotOn::API::Client->search($accountId, {
        q     => sprintf('%s artist:"%s"', $title, $artist),
        type  => 'track',
        limit => 5,
    }, sub {
        my $result = shift;
        my $tracks = ($result && $result->{tracks} && $result->{tracks}{items})
            ? $result->{tracks}{items} : [];

        my $matched = 0;
        if (my ($match) = grep {
                $_->{name} =~ /^\Q$title\E/i
                && $_->{artists} && grep {
                    $_->{name} =~ /\Q$artist\E/i
                } @{$_->{artists}}
            } @$tracks)
        {
            $seedData->{seed_tracks} ||= [];
            push @{$seedData->{seed_tracks}}, $match->{id};
            $matched = 1;
        }

        my $scheduleNext = sub {
            Slim::Utils::Timers::setTimer(
                undef,
                Time::HiRes::time() + DSTM_SEARCH_STAGGER_MS,
                sub { _searchNextSeed($client, $accountId, $itemsRef, $idx + 1, $seedData, $done) }
            );
        };

        if (!$matched) {
            Plugins::SpotOn::API::Client->search($accountId, {
                q     => sprintf('artist:"%s"', $artist),
                type  => 'artist',
                limit => 5,
            }, sub {
                my $result = shift;
                my $artists = ($result && $result->{artists} && $result->{artists}{items})
                    ? $result->{artists}{items} : [];

                if (my ($match) = grep {
                        $_->{name} =~ /\Q$artist\E/i
                    } @$artists)
                {
                    $seedData->{seed_artists} ||= [];
                    push @{$seedData->{seed_artists}}, $match->{id};
                }

                $scheduleNext->();
            });
            return;
        }

        $scheduleNext->();
    });
}

# _searchFallback($client, $accountId, $seedArtist, $cb)
# Artist-search-based track discovery for DSTM.
# Uses a random offset to vary results per invocation.
sub _searchFallback {
    my ($client, $accountId, $seedArtist, $cb) = @_;

    my $offset = int(rand(40));

    main::INFOLOG && $log->info(
        "SpotOn DSTM: artist search (artist=$seedArtist, offset=$offset)"
    );

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => sprintf('artist:"%s"', $seedArtist),
        type   => 'track',
        limit  => 25,
        offset => $offset,
    }, sub {
        my $result = shift;
        my $tracks = ($result && $result->{tracks} && $result->{tracks}{items})
            ? $result->{tracks}{items} : [];

        my @uris = _cacheAndExtractUris($tracks);

        if (@uris) {
            $cb->($client, \@uris);
        }
        else {
            $cb->($client);
        }
    });
}

sub _cacheAndExtractUris {
    my ($tracks) = @_;
    my @uris;

    require Plugins::SpotOn::Plugin;
    my $type_str = Plugins::SpotOn::Plugin->_typeString(undef, 'Browse');

    for my $track (@$tracks) {
        next unless $track->{uri} && $track->{uri} =~ /(track:[a-z0-9]+)/i;
        my $uri = "spoton://$1";

        my $artist = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
        my $images = $track->{album}{images} || [];
        my $image  = @$images ? (sort { ($b->{width}||0) <=> ($a->{width}||0) } @$images)[0]->{url} : '';
        my $year   = Plugins::SpotOn::Plugin::_releaseYear(($track->{album} || {})->{release_date});

        # D-02: 7-day TTL (604800s) so DSTM tracks survive in history for a week
        # WR-01: include artist/album IDs so trackInfoMenu can build navigation items.
        my %trackIds = Plugins::SpotOn::Plugin::_extractTrackIds($track);
        $cache->set('spoton_meta_' . md5_hex($uri), {
            title    => $track->{name} // '',
            artist   => $artist,
            album    => $track->{album}{name} // '',
            duration => ($track->{duration_ms} || 0) / 1000,
            cover    => $image,
            icon     => $image,
            year     => $year,
            bitrate  => Plugins::SpotOn::Plugin->_bitrateForClient(undef) . 'k',
            type     => $type_str,
            %trackIds,
        }, 604800);

        push @uris, $uri;
    }

    return @uris;
}

1;

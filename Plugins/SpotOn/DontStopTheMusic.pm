package Plugins::SpotOn::DontStopTheMusic;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use List::Util qw(min);
use Time::HiRes;

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Schema;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

use constant DSTM_MAX_TRACKS       => 10;
use constant DSTM_SEARCH_STAGGER_S => 0.2;

sub init {
    Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
        'PLUGIN_SPOTON_RECOMMENDATIONS',
        \&dontStopTheMusic
    );
}

sub dontStopTheMusic {
    my ($client, $cb) = @_;

    my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 3);

    if (!$seedTracks || !ref $seedTracks || !scalar @$seedTracks) {
        $cb->($client);
        return;
    }

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';
    unless ($accountId) {
        main::INFOLOG && $log->info("SpotOn DSTM: no active account, skipping");
        $cb->($client);
        return;
    }

    require Plugins::SpotOn::API::Client;

    # Extract unique artist names from seeds.
    # getMixableProperties returns joined artist strings ("A, B, C") —
    # split on ", " and take the first name to avoid Spotify query mismatch.
    my (@seedArtists, %seen);
    foreach my $track (@$seedTracks) {
        next unless $track->{artist};
        my ($first) = split /,\s*/, $track->{artist};
        next unless $first && !$seen{lc $first}++;
        push @seedArtists, $first;
    }

    unless (@seedArtists) {
        main::INFOLOG && $log->info("SpotOn DSTM: no artist seed available, skipping");
        $cb->($client);
        return;
    }

    main::INFOLOG && $log->info("SpotOn DSTM: mixing from artists: " . join(', ', @seedArtists));

    _searchArtists($client, $accountId, \@seedArtists, 0, [], $cb);
}

# _searchArtists — iterate seed artists sequentially with 200ms stagger.
# Collects tracks from each artist, then merges/shuffles/caps the result.
sub _searchArtists {
    my ($client, $accountId, $artists, $idx, $allTracks, $cb) = @_;

    if ($idx >= scalar @$artists) {
        _finalizeResults($client, $allTracks, $cb);
        return;
    }

    my $artist = $artists->[$idx];
    my $limit  = Plugins::SpotOn::API::Client->getLimit('search') || 10;
    my $perArtist = int(DSTM_MAX_TRACKS / scalar(@$artists)) + 1;
    $limit = min($limit, $perArtist);

    main::INFOLOG && $log->info(
        "SpotOn DSTM: artist search (artist=$artist, limit=$limit)"
    );

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => sprintf('artist:"%s"', $artist),
        type   => 'track',
        limit  => $limit,
    }, sub {
        my $result = shift;
        my $tracks = ($result && $result->{tracks} && $result->{tracks}{items})
            ? $result->{tracks}{items} : [];

        push @$allTracks, @$tracks;

        Slim::Utils::Timers::setTimer(
            undef,
            Time::HiRes::time() + DSTM_SEARCH_STAGGER_S,
            sub { _searchArtists($client, $accountId, $artists, $idx + 1, $allTracks, $cb) }
        );
    });
}

# _finalizeResults — shuffle, cap, cache metadata, return URIs to LMS.
sub _finalizeResults {
    my ($client, $allTracks, $cb) = @_;

    unless (@$allTracks) {
        main::INFOLOG && $log->info("SpotOn DSTM: no tracks found for any seed artist");
        $cb->($client);
        return;
    }

    # Fisher-Yates shuffle
    for my $i (reverse 1 .. $#$allTracks) {
        my $j = int(rand($i + 1));
        @$allTracks[$i, $j] = @$allTracks[$j, $i];
    }

    splice @$allTracks, DSTM_MAX_TRACKS if scalar @$allTracks > DSTM_MAX_TRACKS;

    my @uris = _cacheAndExtractUris($allTracks);

    if (@uris) {
        main::INFOLOG && $log->info("SpotOn DSTM: queuing " . scalar(@uris) . " tracks");
        $cb->($client, \@uris);
    }
    else {
        $cb->($client);
    }
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

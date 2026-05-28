package Plugins::SpotOn::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;
use Slim::Utils::Cache;
use Time::HiRes;

my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

my $log = Slim::Utils::Log->addLogCategory( {
    category     => 'plugin.spoton',
    defaultLevel => 'WARN',
    description  => 'PLUGIN_SPOTON',
    logGroups    => 'SCANNER',
} );

sub initPlugin {
    my $class = shift;

    if ( !main::TRANSCODING ) {
        $log->error('Transcoding is required for SpotOn to work');
        return;
    }

    $prefs->init({
        bitrate       => 320,
        binary        => '',    # custom binary override (LMS-10, Phase 6)
        clientId      => '',    # user's Spotify Developer App Client ID (D-04)
        accounts      => {},    # hash: accountId => { displayName => ..., refreshToken => ... }
        activeAccount => '',    # default active account ID (global fallback)
    });

    require Plugins::SpotOn::Helper;
    Plugins::SpotOn::Helper->init();

    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::API::Client;

    # Reset API client inflight counter (Pitfall 2 prevention — stale counter on reload)
    Plugins::SpotOn::API::Client->reset();

    # Start proactive token refresh timer — T-02-15: killTimers first to prevent duplicates
    if ( !main::SCANNER ) {
        Slim::Utils::Timers::killTimers($class, \&_refreshAllTokens);
        Slim::Utils::Timers::setTimer(
            $class,
            Time::HiRes::time() + 10,
            \&_refreshAllTokens
        );
    }

    $VERSION = $class->_pluginDataFor('version');

    Slim::Player::ProtocolHandlers->registerHandler(
        'spotify',
        'Plugins::SpotOn::ProtocolHandler'
    );

    if (main::WEBUI) {
        require Plugins::SpotOn::Settings;
        Plugins::SpotOn::Settings->new();

        # Register OAuth callback route (D-08)
        require Plugins::SpotOn::Settings::Callback;
        Plugins::SpotOn::Settings::Callback->init();
    }

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'spoton',
        menu   => 'radios',
        is_app => 1,
        weight => 100,
        icon   => 'plugins/SpotOn/html/images/icon.png',
    );
}

# _refreshAllTokens()
# Thin timer callback wrapper — Slim::Utils::Timers passes $class as first arg.
sub _refreshAllTokens {
    Plugins::SpotOn::API::TokenManager->refreshAllTokens();
}

sub handleFeed {
    my ($client, $callback, $args) = @_;

    if ( !Plugins::SpotOn::Helper->get() ) {
        $callback->({
            items => [{
                name => cstring($client, 'PLUGIN_SPOTON_BINARY_MISSING'),
                type => 'textarea',
            }]
        });
        return;
    }

    my @items;

    # Rate-limit hint (D-12): show when Spotify API is throttled
    if ( $cache->get(Plugins::SpotOn::API::Client->RATE_LIMIT_CACHE_KEY()) ) {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_RATE_LIMIT_HINT'),
            type => 'textarea',
        };
    }

    # Account switcher (D-05, AUTH-06): first real item when account is configured
    my $activeName = Plugins::SpotOn::API::TokenManager->getActiveAccountName($client);
    if ($activeName) {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_ACTIVE_ACCOUNT', $activeName),
            url  => \&_accountSwitcherFeed,
            type => 'link',
        };

        # D-01: Home, Search, Library as three top-level entries after Account Switcher
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_HOME'),
            url  => \&_homeFeed,
            type => 'link',
        };
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_SEARCH'),
            url  => \&_searchFeed,
            type => 'search',
        };
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_LIBRARY'),
            url  => \&_libraryFeed,
            type => 'link',
        };
    } else {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_ACCOUNT_NONE'),
            type => 'textarea',
        };
    }

    $callback->({ items => \@items });
}

# _accountSwitcherFeed()
# Lists all configured accounts with selection triggering menu refresh.
sub _accountSwitcherFeed {
    my ($client, $callback, $args) = @_;

    my $accounts  = $prefs->get('accounts') || {};
    my $activeId  = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';

    my @items;
    for my $id (sort keys %{$accounts}) {
        my $name    = $accounts->{$id}{displayName} || $id;
        my $isActive = ($id eq $activeId);
        push @items, {
            name        => $name . ($isActive ? ' *' : ''),
            url         => \&_switchAccount,
            passthrough => [{ accountId => $id }],
            type        => 'link',
            nextWindow  => 'refreshOrigin',
        };
    }

    $callback->({ items => \@items });
}

# _switchAccount()
# Updates per-client activeAccount preference and refreshes origin menu.
sub _switchAccount {
    my ($client, $callback, $args, $passthrough) = @_;

    my $accountId = $passthrough && $passthrough->[0] ? $passthrough->[0]{accountId} : undef;

    if ($accountId && $client) {
        $prefs->client($client)->set('activeAccount', $accountId);
        # Also update global default if none is set yet
        $prefs->set('activeAccount', $accountId) unless $prefs->get('activeAccount');
    }

    $callback->({
        items      => [{ name => 'OK', type => 'textarea', showBriefly => 1 }],
        nextWindow => 'refreshOrigin',
    });
}

# ============================================================
# Shared Helper Functions
# ============================================================

# _getAccountId($client)
# Returns the active account ID for the given player client.
# Falls back to global activeAccount pref, then empty string.
sub _getAccountId {
    my ($client) = @_;
    return $prefs->client($client)->get('activeAccount')
        || $prefs->get('activeAccount')
        || '';
}

# _largestImage($images_arrayref)
# Returns the URL of the largest image (by width) from a Spotify images array.
# Returns '' if the array is empty or undef.
# Per PATTERNS.md Artwork pattern and RESEARCH.md Pitfall 6.
sub _largestImage {
    my ($images) = @_;
    return '' unless ref $images eq 'ARRAY' && @{$images};
    my ($largest) = sort { ($b->{width} || 0) <=> ($a->{width} || 0) } @{$images};
    return $largest->{url} || '';
}

# _isMadeForYou($playlist_hashref)
# Returns true if the playlist is a Spotify-generated playlist
# (Daily Mix, Discover Weekly, Release Radar, etc.).
# Detection via owner.id eq 'spotify' — per D-04 and RESEARCH.md Pattern 5.
sub _isMadeForYou {
    my ($playlist) = @_;
    return ($playlist->{owner}{id} // '') eq 'spotify';
}

# _trackItem($client, $track)
# Builds an OPML audio item hashref for a Spotify track.
# Per RESEARCH.md Pattern 3 and PATTERNS.md Track-Item pattern.
# D-06: url and play set to spotify:// URI for Play-Intent.
# D-07: items array carries context navigation (Artist view, Album view).
sub _trackItem {
    my ($client, $track) = @_;
    my $title    = $track->{name} // '';
    my $artist   = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
    my $album    = $track->{album}{name} // '';
    my $image    = _largestImage($track->{album}{images});
    my $duration = ($track->{duration_ms} || 0) / 1000;

    # D-07: Build context navigation items for artist and album drill-down.
    # Only add links when IDs are available (simplified track objects may lack album).
    my @contextItems;
    if ($track->{artists} && @{ $track->{artists} } && $track->{artists}[0]{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_ARTIST_VIEW'),
            url         => \&_artistFeed,
            passthrough => [{ artistId => $track->{artists}[0]{id} }],
            type        => 'link',
        };
    }
    if ($track->{album} && $track->{album}{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_ALBUM_VIEW'),
            url         => \&_albumFeed,
            passthrough => [{ albumId => $track->{album}{id} }],
            type        => 'link',
        };
    }

    my %item = (
        name      => "$title \x{2014} $artist",    # em-dash fallback for older clients
        line1     => $title,
        line2     => $artist . ($album ? " \x{2022} $album" : ''),
        url       => 'spotify://' . ($track->{uri} // ''),
        play      => 'spotify://' . ($track->{uri} // ''),
        on_select => 'play',
        image     => $image,
        duration  => $duration,
        type      => 'audio',
    );
    $item{items} = \@contextItems if @contextItems;

    return \%item;
}

# _albumItem($client, $album)
# Builds an OPML link item for album navigation.
# url => \&_albumFeed is defined in Plan 03-03 (resolved at runtime by Perl).
sub _albumItem {
    my ($client, $album) = @_;
    my $firstArtist = ($album->{artists} && @{$album->{artists}})
        ? $album->{artists}[0]{name}
        : '';
    my $releaseDate = $album->{release_date} // '';
    my $line2 = $firstArtist . ($releaseDate ? " ($releaseDate)" : '');

    return {
        name        => $album->{name} // '',
        url         => \&_albumFeed,                # defined in Plan 03-03
        passthrough => [{ albumId => $album->{id} }],
        image       => _largestImage($album->{images}),
        line2       => $line2,
        type        => 'link',
    };
}

# _artistItem($client, $artist)
# Builds an OPML link item for artist navigation.
# url => \&_artistFeed is defined in Plan 03-03 (resolved at runtime by Perl).
sub _artistItem {
    my ($client, $artist) = @_;
    return {
        name        => $artist->{name} // '',
        url         => \&_artistFeed,               # defined in Plan 03-03
        passthrough => [{ artistId => $artist->{id} }],
        image       => _largestImage($artist->{images}),
        type        => 'link',
    };
}

# _playlistItem($client, $playlist)
# Builds an OPML link item for playlist navigation.
# url => \&_playlistFeed is defined in Plan 03-03 (resolved at runtime by Perl).
sub _playlistItem {
    my ($client, $playlist) = @_;
    return {
        name        => $playlist->{name} // '',
        url         => \&_playlistFeed,             # defined in Plan 03-03
        passthrough => [{ playlistId => $playlist->{id} }],
        image       => _largestImage($playlist->{images}),
        line2       => $playlist->{owner}{display_name} // '',
        type        => 'link',
    };
}

# ============================================================
# Home Feed (D-02)
# ============================================================

# _homeFeed($client, $callback, $args)
# Returns three navigation items: Recently Played, Made For You, Top Tracks.
# Per D-02: each item opens its own sub-feed.
sub _homeFeed {
    my ($client, $callback, $args) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_SPOTON_RECENTLY_PLAYED'),
            url  => \&_recentlyPlayedFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_MADE_FOR_YOU'),
            url  => \&_madeForYouFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_TOP_TRACKS'),
            url  => \&_topTracksFeed,
            type => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _recentlyPlayedFeed($client, $callback, $args)
# Fetches recently played tracks via cursor-based API (no offset — Pitfall 4).
# Single-page response; no total field.
sub _recentlyPlayedFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getRecentlyPlayed($accountId, { limit => 50 }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _trackItem($client, $_->{track}) } @{ $data->{items} || [] };
        $callback->({ items => \@items });
    });
}

# _madeForYouFeed($client, $callback, $args)
# Fetches user playlists and filters to Spotify-generated (Made For You) playlists.
# Uses owner.id eq 'spotify' detection per D-04.
# Note: fetches first 50 playlists — if user has >50 playlists, some Made-For-You
# entries near the end may be missed. Acceptable for Phase 3 (Spotify typically
# puts them near the top of the list).
sub _madeForYouFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getUserPlaylists($accountId, { offset => 0, limit => 50 }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @mfy   = grep { _isMadeForYou($_) } @{ $data->{items} || [] };
        my @items = map  { _playlistItem($client, $_) } @mfy;
        $callback->({ items => \@items });
    });
}

# _topTracksFeed($client, $callback, $args)
# Fetches user's top tracks with time_range=medium_term per D-05.
sub _topTracksFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getTopTracks($accountId, {
        time_range => 'medium_term',
        limit      => 50,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _trackItem($client, $_) } @{ $data->{items} || [] };
        $callback->({ items => \@items });
    });
}

# ============================================================
# Library Feed (D-03)
# ============================================================

# _libraryFeed($client, $callback, $args)
# Returns four navigation items: Liked Songs, Albums, Artists, Playlists.
# Per D-03: Made-For-You playlists excluded from Playlists entry.
sub _libraryFeed {
    my ($client, $callback, $args) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_SPOTON_LIKED_SONGS'),
            url  => \&_savedTracksFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
            url  => \&_savedAlbumsFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_ARTISTS'),
            url  => \&_followedArtistsFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_PLAYLISTS'),
            url  => \&_userPlaylistsFeed,
            type => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _savedTracksFeed($client, $callback, $args)
# Fetches user's liked tracks with LMS OPMLBased offset/limit pagination mapping.
# Per NAV-08: unconditional access (no gating).
# Per NAV-09: API default sort is added_at desc (recently added first).
# Per D-12: LMS index/quantity mapped to Spotify offset/limit.
sub _savedTracksFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;    # Spotify Library max = 50

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getSavedTracks($accountId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _trackItem($client, $_->{track}) } @{ $data->{items} || [] };
        $callback->({ items => \@items, total => $data->{total} });
    });
}

# _savedAlbumsFeed($client, $callback, $args)
# Fetches user's saved albums with LMS OPMLBased pagination mapping.
sub _savedAlbumsFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getSavedAlbums($accountId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _albumItem($client, $_->{album}) } @{ $data->{items} || [] };
        $callback->({ items => \@items, total => $data->{total} });
    });
}

# _followedArtistsFeed($client, $callback, $args)
# Fetches followed artists via cursor-based API (no offset — Pitfall 4/7).
# Single-page response with limit=50; no total field.
sub _followedArtistsFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    # Cursor-based API: no offset parameter (Pitfall 4)
    Plugins::SpotOn::API::Client->getFollowedArtists($accountId, { limit => 50 }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _artistItem($client, $_) } @{ $data->{artists}{items} || [] };
        $callback->({ items => \@items });
    });
}

# _userPlaylistsFeed($client, $callback, $args)
# Fetches user's playlists, excluding Made-For-You playlists (per D-03).
# Note: total from API includes Made-For-You playlists so displayed count may be
# slightly off — this is an accepted limitation documented in the plan (must_haves).
sub _userPlaylistsFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getUserPlaylists($accountId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        # D-03: Exclude Made-For-You playlists from Library Playlists
        my @user  = grep { !_isMadeForYou($_) } @{ $data->{items} || [] };
        my @items = map  { _playlistItem($client, $_) } @user;
        $callback->({ items => \@items, total => $data->{total} });
    });
}

# ============================================================
# Search Feeds (NAV-04, NAV-11, D-10)
# ============================================================

# _searchFeed($client, $callback, $args)
# Entry point for the Search type item. LMS passes the search query in $args->{search}.
# Per D-10: Top Result shown prominently above category sections.
# Categories with 0 results are hidden entirely (D-10).
# Per NAV-11: limit=10 per type (Dev Mode maximum).
sub _searchFeed {
    my ($client, $callback, $args) = @_;

    my $query = $args->{search} // '';
    if ($query eq '') {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
        return;
    }

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => $query,
        type   => 'track,album,artist,playlist',
        limit  => 10,
        offset => 0,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my @items;

        # D-10: Top Result — first track from search results, shown inline (not as sub-menu).
        my $trackItems = $data->{tracks}{items} || [];
        if (@{$trackItems}) {
            my $topTrack = $trackItems->[0];
            push @items, {
                name  => cstring($client, 'PLUGIN_SPOTON_TOP_RESULT'),
                items => [ _trackItem($client, $topTrack) ],
                type  => 'outline',
            };
        }

        # Category sections — skip those with 0 results (D-10).
        my $tracksTotal    = $data->{tracks}{total}    // 0;
        my $albumsTotal    = $data->{albums}{total}    // 0;
        my $artistsTotal   = $data->{artists}{total}   // 0;
        my $playlistsTotal = $data->{playlists}{total} // 0;

        if ($tracksTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_TRACKS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'track' }],
                type        => 'link',
                line2       => "$tracksTotal results",
            };
        }
        if ($albumsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'album' }],
                type        => 'link',
                line2       => "$albumsTotal results",
            };
        }
        if ($artistsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ARTISTS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'artist' }],
                type        => 'link',
                line2       => "$artistsTotal results",
            };
        }
        if ($playlistsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_PLAYLISTS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'playlist' }],
                type        => 'link',
                line2       => "$playlistsTotal results",
            };
        }

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items });
    });
}

# _searchTypeFeed($client, $callback, $args, $passthrough)
# Paginated drill-down into a single search type (track, album, artist, or playlist).
# Per NAV-11: limit capped at 10 (Dev Mode). Maps LMS index/quantity to offset/limit.
sub _searchTypeFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $query  = $passthrough->[0]{query} // '';
    my $type   = $passthrough->[0]{type}  // 'track';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 10;
    my $limit  = $qty > 10 ? 10 : $qty;    # Dev Mode cap: max 10 per type

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => $query,
        type   => $type,
        limit  => $limit,
        offset => $offset,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        # Map singular type name to plural response key (Spotify API convention).
        my %typeToKey = (
            track    => 'tracks',
            album    => 'albums',
            artist   => 'artists',
            playlist => 'playlists',
        );
        my $key       = $typeToKey{$type} // "${type}s";
        my $typeData  = $data->{$key} || {};
        my $resultItems = $typeData->{items} || [];
        my $total     = $typeData->{total}   // 0;

        my @items;
        if ($type eq 'track') {
            @items = map { _trackItem($client, $_) } @{$resultItems};
        } elsif ($type eq 'album') {
            @items = map { _albumItem($client, $_) } @{$resultItems};
        } elsif ($type eq 'artist') {
            @items = map { _artistItem($client, $_) } @{$resultItems};
        } elsif ($type eq 'playlist') {
            @items = map { _playlistItem($client, $_) } @{$resultItems};
        }

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items, total => $total });
    });
}

# ============================================================
# Artist Detail Feeds (NAV-05, D-09)
# ============================================================

# _artistFeed($client, $callback, $args, $passthrough)
# Returns four navigation sections for an artist's discography.
# Per D-09: Albums, Singles, Compilations, Appears On — NO Top Tracks, NO Related Artists
# (both removed in Dev Mode as of Feb 2026 / Nov 2024).
sub _artistFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $artistId = $passthrough->[0]{artistId} // '';

    my @items = (
        {
            name        => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'album' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_SINGLES'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'single' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_COMPILATIONS'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'compilation' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_APPEARS_ON'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'appears_on' }],
            type        => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _artistAlbumsFeed($client, $callback, $args, $passthrough)
# Fetches paginated albums for an artist filtered by a SINGLE include_groups value.
# Per D-09/Pitfall 1: never combine include_groups values — issues separate request per type.
sub _artistAlbumsFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $artistId      = $passthrough->[0]{artistId}      // '';
    my $includeGroups = $passthrough->[0]{includeGroups} // 'album';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getArtistAlbums($accountId, $artistId, {
        include_groups => $includeGroups,
        offset         => $offset,
        limit          => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _albumItem($client, $_) } @{ $data->{items} || [] };
        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }
        $callback->({ items => \@items, total => $data->{total} // 0 });
    });
}

# ============================================================
# Album Detail Feed (NAV-06)
# ============================================================

# _albumFeed($client, $callback, $args, $passthrough)
# Shows numbered tracklist for an album.
# Per NAV-06: line1 = "$track_number. $title", line2 = featuring artists (if differ from album artist).
# For index=0: uses tracks embedded in getAlbum response.
# For index>0: fetches separate getAlbumTracks page.
# Album artwork and artist are passed via passthrough for subsequent pages.
sub _albumFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $albumId      = $passthrough->[0]{albumId}      // '';
    my $albumImages  = $passthrough->[0]{albumImages};    # undef on first load
    my $albumArtist  = $passthrough->[0]{albumArtist}  // '';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    if ($offset == 0) {
        # Initial load: fetch full album (includes first page of tracks in tracks.items).
        Plugins::SpotOn::API::Client->getAlbum($accountId, $albumId, sub {
            my $album = shift;
            unless ($album) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my $images   = $album->{images}           || [];
            my $artist0  = ($album->{artists} && @{$album->{artists}}) ? $album->{artists}[0]{name} : '';
            my $total    = ($album->{tracks} && $album->{tracks}{total}) ? $album->{tracks}{total} : 0;
            my $tracks   = ($album->{tracks} && $album->{tracks}{items}) ? $album->{tracks}{items} : [];

            my @items = map { _albumTrackItem($client, $_, $images, $artist0) } @{$tracks};

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, total => $total });
        });
    } else {
        # Subsequent pages: use getAlbumTracks with correct offset.
        Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, {
            offset => $offset,
            limit  => $limit,
        }, sub {
            my $data = shift;
            unless ($data) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my @items = map { _albumTrackItem($client, $_, $albumImages, $albumArtist) } @{ $data->{items} || [] };

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, total => $data->{total} // 0 });
        });
    }
}

# _albumTrackItem($client, $track, $albumImages, $albumArtist)
# Builds a track item in album context.
# line1: "$track_number. $title" per NAV-06.
# line2: featuring artists — shown only if they differ from the album's primary artist.
# Album images passed from the getAlbum call since simplified track objects lack images.
sub _albumTrackItem {
    my ($client, $track, $albumImages, $albumArtist) = @_;

    my $trackNum  = $track->{track_number} // '';
    my $title     = $track->{name}         // '';
    my $artists   = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
    my $image     = _largestImage($albumImages);
    my $duration  = ($track->{duration_ms} || 0) / 1000;

    # Show featuring artists in line2 only when they differ from album's primary artist.
    my $line2 = ($artists && $artists ne ($albumArtist // '')) ? $artists : '';

    # Context navigation: artist view (no album view — already in album context).
    my @contextItems;
    if ($track->{artists} && @{ $track->{artists} } && $track->{artists}[0]{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_ARTIST_VIEW'),
            url         => \&_artistFeed,
            passthrough => [{ artistId => $track->{artists}[0]{id} }],
            type        => 'link',
        };
    }

    my %item = (
        name      => ($trackNum ? "$trackNum. " : '') . $title,
        line1     => ($trackNum ? "$trackNum. " : '') . $title,
        line2     => $line2,
        url       => 'spotify://' . ($track->{uri} // ''),
        play      => 'spotify://' . ($track->{uri} // ''),
        on_select => 'play',
        image     => $image,
        duration  => $duration,
        type      => 'audio',
    );
    $item{items} = \@contextItems if @contextItems;

    return \%item;
}

# ============================================================
# Playlist Detail Feed (NAV-07)
# ============================================================

# _playlistFeed($client, $callback, $args, $passthrough)
# Shows paginated track list for a playlist.
# Per NAV-07: maps LMS index/quantity to Spotify offset/limit (cap 100).
# Null track entries (local files) are skipped per T-03-10.
# Made-For-You 403 fallback: undef $data returns NO_RESULTS textarea (graceful).
sub _playlistFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $playlistId = $passthrough->[0]{playlistId} // '';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 100 ? 100 : $qty;    # Spotify playlist items max = 100

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getPlaylistItems($accountId, $playlistId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            # Made-For-You 403 or other error — graceful fallback per RESEARCH Open Question 2.
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        # T-03-10: Skip null track entries (local files in playlists return null track objects).
        my @items = map  { _trackItem($client, $_->{track}) }
                    grep { defined $_->{track} }
                    @{ $data->{items} || [] };

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items, total => $data->{total} // 0 });
    });
}

1;

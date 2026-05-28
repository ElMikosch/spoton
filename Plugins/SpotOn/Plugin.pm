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
sub _trackItem {
    my ($client, $track) = @_;
    my $title    = $track->{name} // '';
    my $artist   = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
    my $album    = $track->{album}{name} // '';
    my $image    = _largestImage($track->{album}{images});
    my $duration = ($track->{duration_ms} || 0) / 1000;

    return {
        name      => "$title \x{2014} $artist",    # em-dash fallback for older clients
        line1     => $title,
        line2     => $artist . ($album ? " \x{2022} $album" : ''),
        url       => 'spotify://' . ($track->{uri} // ''),
        play      => 'spotify://' . ($track->{uri} // ''),
        on_select => 'play',
        image     => $image,
        duration  => $duration,
        type      => 'audio',
    };
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
# Forward declarations: sub-feeds defined in Plan 03-03
# ============================================================
# These sub references are resolved at runtime by Perl.
# The subs _searchFeed, _artistFeed, _albumFeed, _playlistFeed
# are defined in Plan 03-03 (Plugins/SpotOn/Plugin.pm extension).
# No forward declaration needed in Perl — \&sub resolves at call time.

1;

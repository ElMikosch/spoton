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
use Digest::MD5 qw(md5_hex);
use Time::HiRes;
use File::Basename;
use File::Spec::Functions qw(catdir);
use Slim::Player::TranscodingHelper;

use constant KILL_PROCESS_INTERVAL => 3600;    # Stundlicher Orphaned-Process-Cleanup (STR-10)

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
        bitrate              => 320,
        normalization        => 0,     # STR-08: volume normalisation toggle, default off (D-06)
        binary               => '',    # custom binary override (LMS-10, Phase 6)
        accounts             => {},    # hash: accountId => { displayName => '...', spotifyUserId => '...' }
        activeAccount        => '',    # default active account ID (global fallback)
        enableSpotifyConnect => 1,     # CON-10: per-player Connect toggle, default on
        connectOggOverride   => 'auto', # D-05: OGG passthrough override ('auto'|'ogg'|'pcm')
        disableDiscovery     => 0,     # D-04: global discovery toggle, default on (Pitfall 4)
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

        # Orphaned-Process-Cleanup-Timer starten (STR-10)
        Slim::Utils::Timers::killTimers($class, \&_killOrphanedProcesses);
        Slim::Utils::Timers::setTimer(
            $class,
            Time::HiRes::time() + KILL_PROCESS_INTERVAL,
            \&_killOrphanedProcesses
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

        # D-01: Auto-start ZeroConf Discovery if no credentials exist.
        # Deferred via timer to not block initPlugin.
        Slim::Utils::Timers::killTimers(undef, \&_autoStartDiscovery);
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&_autoStartDiscovery);

        # D-07: Start Connect daemon manager for all players.
        # 3s delay allows player list to populate after LMS start.
        Slim::Utils::Timers::killTimers($class, \&_startConnectDaemons);
        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 3, \&_startConnectDaemons);
    }

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'spoton',
        menu   => 'radios',
        is_app => 1,
        weight => 100,
        icon   => 'plugins/SpotOn/html/images/SpotOn_MTL_svg_spoton.png',
    );
}

# _refreshAllTokens()
# Thin timer callback wrapper — Slim::Utils::Timers passes $class as first arg.
sub _refreshAllTokens {
    Plugins::SpotOn::API::TokenManager->refreshAllTokens();
}

# _autoStartDiscovery()
# D-01: Timer callback — auto-starts ZeroConf discovery if no credentials exist.
sub _autoStartDiscovery {
    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->autoStartDiscoveryIfNeeded();
}

# _startConnectDaemons()
# D-07: Timer callback — starts Connect daemon manager at LMS boot.
# Guarded by main::WEBUI (called only from the WEBUI block in initPlugin).
# 3s delay allows player list to populate before daemon lifecycle starts.
sub _startConnectDaemons {
    require Plugins::SpotOn::Connect;
    Plugins::SpotOn::Connect->init();
}

# _killOrphanedProcesses($class)
# Cleans up orphaned librespot processes when no player is actively playing.
# Runs every KILL_PROCESS_INTERVAL seconds (STR-10).
# IMPORTANT: Slim::Player::Client is NOT explicitly imported — LMS autoloads it.
sub _killOrphanedProcesses {
    my ($class) = @_;

    Slim::Utils::Timers::killTimers($class, \&_killOrphanedProcesses);

    # CR-01/WR-04: Only check Spotify-playing clients (not all protocols).
    # This prevents false positives (non-Spotify playback blocking cleanup)
    # and reduces the race window during Spotify track transitions.
    my $isBusy = 0;
    my %activePids;
    for my $client (Slim::Player::Client::clients()) {
        my $song = $client->playingSong() || next;
        my $url  = $song->currentTrack() ? $song->currentTrack()->url : '';
        next unless $url =~ m{^spotify://};

        if ($client->isPlaying()) {
            main::DEBUGLOG && $log->is_debug && $log->debug("Spotify player " . $client->name() . " is busy, skipping orphan cleanup");
            $isBusy = 1;
        }

        # Track PIDs of active transcoding processes to protect them from kill
        my $pid = $song->transcodeProcess() if $song->can('transcodeProcess');
        $activePids{$pid} = 1 if $pid;
    }

    unless ($isBusy) {
        my ($helper) = Plugins::SpotOn::Helper->get();
        if ($helper) {
            eval {
                if (main::ISWINDOWS) {
                    my $name = basename($helper);
                    $name =~ s/[^A-Za-z0-9._-]//g;    # CR-02: Whitelist statt Blacklist — verhindert Shell-Injection via &, |, ;
                    if ($name) {
                        system(qq{taskkill /IM "$name" /F 1>nul 2>&1});
                    }
                } else {
                    # CR-01: Use PID-based kill to avoid killing active transcoding processes.
                    # Find all matching PIDs, exclude active ones, kill only orphans.
                    # CON-09: Exclude Connect daemon PIDs from orphan cleanup (Pitfall 6).
                    my %connectPids;
                    if ($INC{'Plugins/SpotOn/Connect/DaemonManager.pm'}) {
                        %connectPids = map { $_ => 1 }
                            Plugins::SpotOn::Connect::DaemonManager->helperPids();
                    }

                    (my $safeHelper = $helper) =~ s/'/'\\''/g;
                    my @pids = map { /^\s*(\d+)/ ? $1 : () } `pgrep -f '$safeHelper'`;
                    for my $pid (@pids) {
                        next if $activePids{$pid};
                        next if $connectPids{$pid};    # CON-09: protect Connect daemon PIDs
                        kill 'TERM', $pid;
                        main::DEBUGLOG && $log->is_debug && $log->debug("Killed orphaned spoton process PID $pid");
                    }
                }
            };
            $@ && $log->warn("Could not kill orphaned spoton processes: $@");
        }
    }

    # Always reschedule (even when $isBusy) to maintain hourly cleanup cycle
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + KILL_PROCESS_INTERVAL,
        \&_killOrphanedProcesses
    );
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

    # Rate-limit hint (D-12): show when either token flavor is throttled
    if ( $cache->get('spoton_rate_limit_own') || $cache->get('spoton_rate_limit_bundled') ) {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_RATE_LIMIT_HINT'),
            type => 'textarea',
        };
    }

    # Account switcher: only show when multiple accounts configured
    my $activeName = Plugins::SpotOn::API::TokenManager->getActiveAccountName($client);
    my $accountCount = scalar Plugins::SpotOn::API::TokenManager->getAccountIds();
    if ($activeName) {
        if ($accountCount > 1) {
            push @items, {
                name => cstring($client, 'PLUGIN_SPOTON_ACTIVE_ACCOUNT', $activeName),
                url  => \&_accountSwitcherFeed,
                type => 'link',
            };
        }

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

    my $accountId = $passthrough ? $passthrough->{accountId} : undef;

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

# Regex-Muster fuer Spotify-generierte Personal-Mix-Playlists (D-06).
# Verwendet \s+ statt Leerzeichen fuer Whitespace-Varianten.
# BEIDE Aufrufstellen (_madeForYouFeed und _libraryPlaylistsFeed)
# nutzen _isMadeForYou — nur diese Funktion aendern reicht (RESEARCH.md Pitfall 4).
my $PERSONAL_MIX_REGEX = qr/Daily\s+Mix|MixTape|Discover\s+Weekly|Mix\s+der\s+Woche|Release\s+Radar/i;

# _isMadeForYou($playlist_hashref)
# Returns true if the playlist is a Spotify-generated personal mix.
# Detection via name-matching (D-06) — replaces broken owner.id eq 'spotify' filter
# which fails in Dev Mode (Feb 2026: owner fields restricted).
sub _isMadeForYou {
    my ($playlist) = @_;
    return ($playlist->{name} // '') =~ $PERSONAL_MIX_REGEX;
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

    # T-04.1-01: Extract path from Spotify URI to prevent double-prefix.
    # spotify:track:ID -> track:ID; fallback preserves original URI if no match.
    my ($track_path) = ($track->{uri} // '') =~ /^spotify:((?:track|episode):.+)/;
    $track_path //= ($track->{uri} // '');
    my $spotify_url = 'spotify://' . $track_path;

    # Cache metadata for getMetadataFor (STR-03): NowPlaying artwork + title display
    $cache->set('spoton_meta_' . md5_hex($spotify_url), {
        title    => $title,
        artist   => $artist,
        album    => $album,
        duration => $duration,
        cover    => $image,
        icon     => $image,
        bitrate  => ($prefs->get('bitrate') || 320) . 'k',
        type     => 'Spotify',
    }, 3600);

    my %item = (
        name      => "$title \x{2014} $artist",    # em-dash fallback for older clients
        line1     => $title,
        line2     => $artist . ($album ? " \x{2022} $album" : ''),
        url       => $spotify_url,
        play      => $spotify_url,
        on_select => 'play',
        playall   => 1,    # Kontext-Queueing (D-09/D-10) — XMLBrowser reiht alle Items des Feeds ein
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
        name          => $album->{name} // '',
        url           => \&_albumFeed,
        passthrough   => [{ albumId => $album->{id}, albumImages => $album->{images}, albumArtist => $firstArtist, albumName => $album->{name} }],
        image         => _largestImage($album->{images}),
        line2         => $line2,
        favorites_url => $album->{uri},
        type          => 'playlist',
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
        name          => $playlist->{name} // '',
        url           => \&_playlistFeed,
        passthrough   => [{ playlistId => $playlist->{id} }],
        image         => _largestImage($playlist->{images}),
        line2         => $playlist->{owner}{display_name} // '',
        favorites_url => $playlist->{uri},
        type          => 'playlist',
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

# Priority tiers for Made For You sorting (matched against English names).
my @MFY_PRIORITY = (
    qr/^daylist$/i,
    qr/^Discover Weekly$/i,
    qr/^Release Radar$/i,
    qr/^Daily Mix \d+$/i,
    qr/^On Repeat$/i,
    qr/^Repeat Rewind$/i,
);

sub _madeForYouPriority {
    my ($name) = @_;
    for my $i (0 .. $#MFY_PRIORITY) {
        return $i if $name =~ $MFY_PRIORITY[$i];
    }
    return scalar @MFY_PRIORITY;
}

# _fetchAllPersonalMixes($accountId, $locale, $cb)
# Fetches all pages of personal mixes. $locale is optional (undef = user default).
# Calls $cb->(\@playlists) with valid (non-null) items from all pages.
sub _fetchAllPersonalMixes {
    my ($accountId, $locale, $cb) = @_;
    my %params = (limit => 50);
    $params{_locale} = $locale if $locale;

    Plugins::SpotOn::API::Client->getPersonalMixes($accountId, \%params, sub {
        my $data = shift;
        my $items = $data && $data->{playlists} ? $data->{playlists}{items} : [];
        my @valid = grep { $_ && $_->{id} } @$items;
        my $total = $data && $data->{playlists} ? ($data->{playlists}{total} || 0) : 0;

        if ($total > 50) {
            my %p2 = (limit => 50, offset => 50);
            $p2{_locale} = $locale if $locale;
            Plugins::SpotOn::API::Client->getPersonalMixes($accountId, \%p2, sub {
                my $page2 = shift;
                if ($page2 && $page2->{playlists} && $page2->{playlists}{items}) {
                    push @valid, grep { $_ && $_->{id} } @{ $page2->{playlists}{items} };
                }
                $cb->(\@valid);
            });
        } else {
            $cb->(\@valid);
        }
    });
}

# _madeForYouFeed($client, $callback, $args)
# Fetches personal mixes in two parallel requests: localized (for display) and
# English (for locale-independent sorting). Merges by playlist ID.
sub _madeForYouFeed {
    my ($client, $callback, $args) = @_;
    my $accountId = _getAccountId($client);

    my ($localized, %en_names);
    my $pending = 2;

    my $merge = sub {
        return if --$pending > 0;

        unless ($localized && @$localized) {
            $callback->({ items => [{ name => cstring($client,
                'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my @sorted = sort {
            _madeForYouPriority($en_names{$a->{id}} // $a->{name} // '')
            <=>
            _madeForYouPriority($en_names{$b->{id}} // $b->{name} // '')
        } @$localized;

        my @items = map { _playlistItem($client, $_) } @sorted;
        $callback->({ items => \@items });
    };

    _fetchAllPersonalMixes($accountId, undef, sub {
        $localized = shift;
        $merge->();
    });

    _fetchAllPersonalMixes($accountId, 'en', sub {
        my $en = shift || [];
        %en_names = map { $_->{id} => $_->{name} } @$en;
        $merge->();
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
        $callback->({ items => \@items, offset => $offset, total => $data->{total} });
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
        $callback->({ items => \@items, offset => $offset, total => $data->{total} });
    });
}

# _followedArtistsFeed($client, $callback, $args)
# Fetches ALL followed artists by chaining cursor-based API calls.
# Spotify's /me/following uses cursor pagination (no offset — Pitfall 4/7).
# We fetch 50 at a time until no more cursors remain, then return all at once.
sub _followedArtistsFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    _fetchAllFollowedArtists($client, $accountId, undef, [], sub {
        my ($allArtists) = @_;
        my @items = map { _artistItem($client, $_) } @{$allArtists};
        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }
        $callback->({ items => \@items });
    });
}

sub _fetchAllFollowedArtists {
    my ($client, $accountId, $after, $accumulated, $done) = @_;

    my %params = (limit => 50);
    $params{after} = $after if defined $after;

    Plugins::SpotOn::API::Client->getFollowedArtists($accountId, \%params, sub {
        my $data = shift;
        unless ($data) {
            $done->($accumulated);
            return;
        }
        my $artists = $data->{artists}{items} || [];
        push @{$accumulated}, @{$artists};

        my $nextCursor = $data->{artists}{cursors}{after} // '';
        if ($nextCursor ne '' && @{$artists} > 0) {
            _fetchAllFollowedArtists($client, $accountId, $nextCursor, $accumulated, $done);
        } else {
            $done->($accumulated);
        }
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
        $callback->({ items => \@items, offset => $offset, total => $data->{total} });
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

    my $query  = $passthrough->{query} // '';
    my $type   = $passthrough->{type}  // 'track';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 10;
    my $limit  = $qty > 10 ? 10 : $qty;

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

        $callback->({ items => \@items, offset => $offset, total => $total });
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

    my $artistId = $passthrough->{artistId} // '';

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

    my $artistId      = $passthrough->{artistId}      // '';
    my $includeGroups = $passthrough->{includeGroups} // 'album';

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
        $callback->({ items => \@items, offset => $offset, total => $data->{total} // 0 });
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

    my $albumId      = $passthrough->{albumId}      // '';
    my $albumImages  = $passthrough->{albumImages};    # undef on first load
    my $albumArtist  = $passthrough->{albumArtist}  // '';
    my $albumName    = $passthrough->{albumName}    // '';    # WR-01: carried for metadata cache

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

            my @items = map { _albumTrackItem($client, $_, $images, $artist0, $album->{name}) } @{$tracks};

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, offset => 0, total => $total });
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

            my @items = map { _albumTrackItem($client, $_, $albumImages, $albumArtist, $albumName) } @{ $data->{items} || [] };

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, offset => $offset, total => $data->{total} // 0 });
        });
    }
}

# _albumTrackItem($client, $track, $albumImages, $albumArtist, $albumName)
# Builds a track item in album context.
# line1: "$track_number. $title" per NAV-06.
# line2: featuring artists — shown only if they differ from the album's primary artist.
# Album images passed from the getAlbum call since simplified track objects lack images.
# WR-01: $albumName passed from caller for metadata cache (simplified track objects lack album name).
sub _albumTrackItem {
    my ($client, $track, $albumImages, $albumArtist, $albumName) = @_;

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

    # T-04.1-01: Extract path from Spotify URI to prevent double-prefix.
    # spotify:track:ID -> track:ID; fallback preserves original URI if no match.
    my ($track_path) = ($track->{uri} // '') =~ /^spotify:((?:track|episode):.+)/;
    $track_path //= ($track->{uri} // '');
    my $spotify_url = 'spotify://' . $track_path;

    # Cache metadata for getMetadataFor (STR-03): NowPlaying artwork + title display.
    # WR-01: Album name passed from caller; fallback to empty if undef (e.g., future callers).
    $albumName //= '';
    $cache->set('spoton_meta_' . md5_hex($spotify_url), {
        title    => $title,
        artist   => $artists,
        album    => $albumName,
        duration => $duration,
        cover    => $image,
        icon     => $image,
        bitrate  => ($prefs->get('bitrate') || 320) . 'k',
        type     => 'Spotify',
    }, 3600);

    my %item = (
        name      => ($trackNum ? "$trackNum. " : '') . $title,
        line1     => ($trackNum ? "$trackNum. " : '') . $title,
        line2     => $line2,
        url       => $spotify_url,
        play      => $spotify_url,
        on_select => 'play',
        playall   => 1,    # Kontext-Queueing fuer Album-Track-Tap (D-09)
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

    my $playlistId = $passthrough->{playlistId} // '';

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

        $callback->({ items => \@items, offset => $offset, total => $data->{total} // 0 });
    });
}


# ============================================================
# Transcoding Engine (STR-01 through STR-08, LMS-11)
# ============================================================

# updateTranscodingTable($client)
# Injects runtime parameters (bitrate, cache dir, helper name, volume normalization)
# into LMS commandTable for all son-* single-track pipeline entries.
# Called from ProtocolHandler::formatOverride before each track start (D-01, Pattern 1).
# This approach avoids pref-file caching in TranscodingHelper (RESEARCH.md Anti-Pattern 1).
# LMS single-threaded event loop guarantees no race condition (LMS-11).
sub updateTranscodingTable {
    my ($class, $client) = @_;

    my $bitrate   = $prefs->get('bitrate')      || 320;
    my $normalize = $prefs->get('normalization') || 0;    # Phase 4: global toggle (D-06)

    # Per-player bitrate override (D-01, T-06-05): re-validated here before regex substitution
    # Only valid numeric values (96/160/320) reach the --bitrate regex — prevents injection
    if ($client) {
        my $override = $prefs->client($client)->get('bitrateOverride');
        $bitrate = $override if $override && $override =~ /^(?:96|160|320)$/;
    }

    # Compute librespot credentials/session cache dir (Pattern 4)
    # Multi-account: inject active accountId into cache path (RESEARCH Pitfall 6)
    # This ensures --single-track finds the correct credentials.json for the active account.
    my $serverPrefs     = preferences('server');
    my $activeAccountId = $prefs->get('activeAccount') || '';
    my $cacheDir = $activeAccountId
        ? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
        : catdir($serverPrefs->get('cachedir'), 'spoton');

    # Create cache dir if it does not exist
    unless (-d $cacheDir) {
        require File::Path;
        File::Path::make_path($cacheDir);
    }

    # Get helper binary name — used to update [spoton] placeholder in commandTable
    my ($helper) = Plugins::SpotOn::Helper->get();
    my $helperName = $helper ? basename($helper) : 'spoton';

    my $commandTable = Slim::Player::TranscodingHelper::Conversions();
    foreach my $key (keys %{$commandTable}) {
        # Only modify son-* entries that use --single-track (skip Connect/other pipelines)
        next unless $key =~ /^son-/ && $commandTable->{$key} =~ /single-track/;

        # Cache dir injection (Pitfall 4: regex matches any content between quotes)
        $commandTable->{$key} =~ s/-c "[^"]*"/-c "$cacheDir"/g;

        # Bitrate injection
        $commandTable->{$key} =~ s/--bitrate \d+/--bitrate $bitrate/;

        # Helper binary name injection (LMS-10 preparation for custom binary support)
        $commandTable->{$key} =~ s/\[spoton[^\]]*\]/[$helperName]/g;

        # Volume normalisation: always remove first, then conditionally add (STR-08)
        # Removal of flag ensures idempotent behavior across repeated calls
        $commandTable->{$key} =~ s/ --enable-volume-normalisation//g;
        if ($normalize) {
            my $before = $commandTable->{$key};
            $commandTable->{$key} =~ s/( -n )/ --enable-volume-normalisation $1/;
            if ($commandTable->{$key} eq $before) {
                $log->warn("updateTranscodingTable: could not inject --enable-volume-normalisation for $key");
            }
        }

        # NOTE: --disable-audio-cache is NOT touched here (STR-11, D-07)
        # It is hardcoded in custom-convert.conf and the regex patterns above do not match it

        main::INFOLOG && $log->is_info && $log->info("updateTranscodingTable: $key => $commandTable->{$key}");
    }

    # OGG-Passthrough Guard: remove son-ogg entry when binary lacks passthrough (STR-05)
    # Prevents LMS from selecting the son-ogg-*-* profile on players that support OGG
    # natively but where librespot was not built with the passthrough-decoder feature.
    require Plugins::SpotOn::Helper;
    unless (Plugins::SpotOn::Helper->getCapability('passthrough')) {
        delete $commandTable->{'son-ogg-*-*'};
        delete $commandTable->{'soc-ogg-*-*'};    # same guard for Connect OGG passthrough
    }

    # Per-player streamFormat: controls which OGG pipeline entries are active (D-11, D-12)
    # Migration fallback: read new streamFormat first, fall back to old connectOggOverride
    if ($client) {
        my $fmt = $prefs->client($client)->get('streamFormat')
               || $prefs->client($client)->get('connectOggOverride')
               || 'auto';
        # Only keep OGG pipeline entries when user explicitly selects 'ogg' format
        # For pcm/flac/mp3/auto: remove OGG entries so LMS uses the PCM/son pipeline
        if ($fmt ne 'ogg') {
            delete $commandTable->{'son-ogg-*-*'};
            delete $commandTable->{'soc-ogg-*-*'};
        }
    }
}

1;

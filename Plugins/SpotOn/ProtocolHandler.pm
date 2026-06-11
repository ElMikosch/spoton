package Plugins::SpotOn::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Versions;
use Slim::Utils::Cache;
use Slim::Utils::Network;
use Digest::MD5 qw(md5_hex);

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', 3);
my $CRLF  = "\x0d\x0a";

# D-05: debounce — one in-flight re-fetch per URL
our %_pendingRefetch;

# Track Connect URLs translated to Browse by getNextTrack
my %_translatedConnectUrls;

sub contentType { 'son' }

sub isRemote    { 1 }

# getFormatForURL($class, $url)
# Returns content type for a given URL:
# - 'soc' for Connect URLs (spoton://connect-*)
# - 'son' for single-track Browse URLs (default)
sub getFormatForURL {
    my ($class, $url) = @_;
    return 'soc' if $url && $url =~ m{spoton://connect-};
    return 'pcm' if $url && $url =~ m{:\d+/stream\b};
    return 'son';
}

# formatOverride($class, $song)
# Returns the content type (INPUT side of transcoding key) for the current song.
# Checks if a Connect daemon is active; returns 'soc' if so (D-04).
# Otherwise returns 'son' for single-track Browse mode.
#
# LMS Song.pm constructs the transcoding profile key as:
#   formatOverride-outputFormat-*-*  (e.g. soc-pcm-*-* for Connect PCM)
sub formatOverride {
    my ($class, $song) = @_;

    my $client = $song->master;
    my $url = $song->track->url || '';

    require Plugins::SpotOn::Plugin;
    Plugins::SpotOn::Plugin->updateTranscodingTable($client);

    # Per-player streamFormat pref: determines Browse mode pipeline (D-11, D-12)
    # Migration fallback: read new streamFormat first, fall back to old connectOggOverride
    my $fmt = $client
        ? ($prefs->client($client)->get('streamFormat')
           || $prefs->client($client)->get('connectOggOverride')
           || 'auto')
        : 'auto';

    if ($url =~ m{spoton://connect-}) {
        # Dead history URL → use Browse pipeline ('son'), not Connect ('soc')
        my $meta = $cache->get('spoton_meta_' . md5_hex($url));
        if ($meta && $meta->{spotifyUri}) {
            return 'son';
        }

        require Plugins::SpotOn::Connect::DaemonManager;
        my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client);
        if ($helper && $helper->_streamMode) {
            return 'soc';  # Connect: always 'soc', independent of streamFormat
        }
    }

    # Browse mode: always 'son' — pipeline selection via updateTranscodingTable deletion.
    # OGG passthrough uses son-ogg-*-* (not ogg-*-*-* which doesn't exist).
    return 'son';
}

# canDirectStream($class, $client, $url)
# Returns HTTP URL for single Connect players, 0 for sync groups and non-Connect.
# D-06: canDirectStream returns HTTP URL for single players; sync groups use new() proxy.
# T-05-16: URL is constructed from Slim::Utils::Network::serverAddr() + daemon port —
# both LMS-controlled, no user input in URL.
sub canDirectStream {
    my ($class, $client, $url) = @_;

    return 0 unless $client;

    # DirectStream is only valid for Connect streams — Browse tracks use son-* pipelines
    return 0 unless $url && $url =~ m{spoton://connect-};

    # Translated history URL — use Browse transcoding pipeline, not Connect DirectStream
    if (delete $_translatedConnectUrls{$url}) {
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: 0 (translated Connect history URL)"
        );
        return 0;
    }

    $client = $client->master if $client->can('master');

    # Per-player streamFormat: pcm/flac/mp3 force transcoding — no DirectStream (D-11)
    {
        my $fmt = $prefs->client($client)->get('streamFormat')
               || $prefs->client($client)->get('connectOggOverride')
               || 'auto';
        if ($fmt =~ /^(?:pcm|flac|mp3)$/) {
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (streamFormat=$fmt forces transcoding)"
            );
            return 0;
        }
    }

    require Plugins::SpotOn::Connect::DaemonManager;
    my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client);
    unless ($helper && $helper->_streamMode && $helper->_streamPort) {
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: 0 (no helper/streamMode/streamPort)"
        );
        return 0;
    }

    if ($client->isSynced()) {
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: 0 (player is synced)"
        );
        return 0;
    }

    my $host = Slim::Utils::Network::serverAddr();
    my $ds_url = 'http://' . $host . ':' . $helper->_streamPort . '/stream';
    main::INFOLOG && $log->is_info && $log->info(
        "canDirectStream: $ds_url"
    );
    return $ds_url;
}

# requestString($self, $client, $url, $post, $seekdata)
# Override to suppress Range header for Connect proxy connections.
# The base class (HTTP.pm line 971) unconditionally adds "Range: bytes=0-".
# Sending Range to an infinite PCM stream endpoint may cause hyper to respond with
# 206 Partial Content, and triggers LMS's "Persistent service" reconnect path
# (HTTP.pm line 107: !$self->contentLength with Range present). For the binary's
# /stream endpoint, a plain GET without Range is the correct request.
# Non-stream URLs delegate to the base class unchanged (SUPER::requestString).
sub requestString {
    my ($self, $client, $url, $post, $seekdata) = @_;

    if ($url && $url =~ m{:\d+/stream\b}) {
        my ($server, $port, $path) = Slim::Utils::Misc::crackURL($url);
        my $host = ($port == 80) ? $server : "$server:$port";
        main::INFOLOG && $log->is_info && $log->info(
            "requestString: Connect proxy — plain GET (no Range) for $url"
        );
        return join($CRLF,
            "GET $path HTTP/1.0",
            "Accept: */*",
            "Cache-Control: no-cache",
            "Connection: close",
            "Host: $host",
            "", "",
        );
    }

    return $self->SUPER::requestString($client, $url, $post, $seekdata);
}

# canEnhanceHTTP($self, $client, $url)
# Override to return 0 for Connect proxy stream URLs.
# The base class returns $prefs->get('useEnhancedHTTP') which may be non-zero.
# For infinite PCM streams the "Enhanced/Persistent" path (HTTP.pm line 107)
# causes immediate disconnection via range-based reconnections against an
# infinite body. Returning 0 forces LMS to use the normal non-enhanced path.
# Non-stream URLs delegate to the base class unchanged (SUPER::canEnhanceHTTP).
sub canEnhanceHTTP {
    my ($self, $client, $url) = @_;

    if ($url && $url =~ m{:\d+/stream\b}) {
        main::INFOLOG && $log->is_info && $log->info(
            "canEnhanceHTTP: Connect proxy — returning 0 for $url"
        );
        return 0;
    }

    return $self->SUPER::canEnhanceHTTP($client, $url);
}

# new($class, $args)
# Two responsibilities:
# (a) D-08 Browse→Connect mutual exclusion: son:// URL starting while Connect is active
#     → stop the Connect daemon before returning normal stream object
# (b) D-06 Sync-group proxy: spoton://connect-* URL for synced players
#     → substitute HTTP URL so all sync members get audio from binary's HTTP server
#
# Note: DaemonManager require is on-demand (not at top level) per plan acceptance criteria.
sub new {
    my ($class, $args) = @_;

    my $url = $args->{url} || '';

    # (a) D-08: spoton:// (Browse/single-track) URL while Connect is active
    # Stop the Connect daemon so Browse can proceed cleanly.
    if ($url =~ m{^spoton://(?!connect-)}) {
        my $client = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            require Plugins::SpotOn::Connect;
            if (Plugins::SpotOn::Connect->isSpotifyConnect($client)) {
                main::INFOLOG && $log->is_info && $log->info(
                    "D-08: Browse URL — stopping active Connect daemon for " . $client->id
                );
                Plugins::SpotOn::Connect->_stopConnectDaemon($client);
            }
        }
    }

    # (b) D-06: spoton://connect-* URL — substitute HTTP stream URL for sync-group proxy
    if ($url =~ m{spoton://connect-}) {
        my $client = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            require Plugins::SpotOn::Connect::DaemonManager;
            my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client);
            if ($helper && $helper->_streamMode && $helper->_streamPort) {
                my $host    = Slim::Utils::Network::serverAddr();
                my $httpUrl = 'http://' . $host . ':' . $helper->_streamPort . '/stream';
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect sync proxy: substituting HTTP URL $httpUrl for " . $client->id
                );
                $args = { %$args, url => $httpUrl };
            } else {
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect URL but no active stream daemon for " . ($client ? $client->id : '?') . " — returning undef"
                );
                return undef;
            }
        }
    }

    return Slim::Player::Protocols::HTTP->new($args);
}

# getNextTrack($class, $song, $successCb, $errorCb)
# Called by StreamingController before transcoding pipeline starts.
# Translates dead Connect history URLs to Browse URLs so the binary
# receives a valid spoton://track:ID instead of spoton://connect-TIMESTAMP.
sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->track->url || '';
    if ($url =~ m{spoton://connect-}) {
        my $client = $song->master;

        # Dead history URL check FIRST — takes priority over active Connect session.
        # A history URL has a cached spotifyUri (written by _fetchTrackMetadata after
        # the original Connect playback). Translate to Browse regardless of whether
        # the phone is still connected.
        my $meta = $cache->get('spoton_meta_' . md5_hex($url));
        if ($meta && $meta->{spotifyUri}
            && $meta->{spotifyUri} =~ m/^spotify:track:([A-Za-z0-9]+)$/) {
            my $browseUrl = "spoton://track:$1";
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: translating dead Connect URL to $browseUrl"
            );
            $song->streamUrl($browseUrl);
            $_translatedConnectUrls{$url} = 1;
            $successCb->();
            return;
        }

        # No cached spotifyUri — either a live Connect session or an untranslatable URL
        require Plugins::SpotOn::Connect;
        if (Plugins::SpotOn::Connect->isSpotifyConnect($client)) {
            $successCb->();
            return;
        }

        main::INFOLOG && $log->is_info && $log->info(
            "getNextTrack: dead Connect URL with no cached spotifyUri — cannot translate"
        );
        $errorCb->('PROBLEM_OPENING', 'No cached track ID for Connect history URL');
        return;
    }

    $successCb->();
}

sub isRepeatingStream {
    my (undef, $song) = @_;
    return unless $song;
    my $url = $song->track->url || '';
    return $url =~ m{spoton://connect-} ? 1 : 0;
}

sub canSeek {
    my ($class, $client) = @_;
    if ($client) {
        my $song = $client->playingSong();
        my $url = $song ? ($song->track->url || '') : '';
        return 0 if $url =~ m{spoton://connect-};
    }
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub canTranscodeSeek {
    my ($class, $client) = @_;
    if ($client) {
        my $song = $client->playingSong();
        my $url = $song ? ($song->track->url || '') : '';
        return 0 if $url =~ m{spoton://connect-};
    }
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
}

# getMetadataFor($class, $client, $url)
# Returns cached track metadata for NowPlaying display (artwork, title, artist, album,
# duration, bitrate, type).
# - For Connect streams: uses song pluginData('info') set by Connect.pm _fetchTrackMetadata
# - For Browse streams: uses cache populated by Plugin.pm _trackItem/_albumTrackItem
# Cache key: 'spoton_meta_' + md5_hex(url). TTL: 3600s.
# Per STR-03: LMS calls this to populate the NowPlaying display.
sub getMetadataFor {
    my ($class, $client, $url) = @_;

    # For Connect streams: try pluginData info first (set by Connect.pm _fetchTrackMetadata)
    if ($url && $url =~ m{spoton://connect-} && $client) {
        $client = $client->master if $client->can('master');
        my $song = $client->playingSong();
        if ($song && (my $info = $song->pluginData('info'))) {
            return $info;
        }
    }

    # D-06, D-07: Connect history URL translation — cache hit with spotifyUri
    # History items don't have an active playingSong, so we reach here for connect- URLs
    # that were cached by _fetchTrackMetadata in Connect.pm.
    if ($url && $url =~ m{spoton://connect-}) {
        my $connect_meta = $cache->get('spoton_meta_' . md5_hex($url));
        if ($connect_meta && $connect_meta->{spotifyUri}
            && $connect_meta->{spotifyUri} =~ m/^spotify:track:([A-Za-z0-9]+)$/) {
            my $trackId    = $1;
            my $browseUrl  = "spoton://track:$trackId";
            # D-07: return Browse mode label — Connect origin is invisible to the user
            require Plugins::SpotOn::Plugin;
            if ($client) {
                return { %$connect_meta,
                    type    => Plugins::SpotOn::Plugin->_typeString($client, 'Browse'),
                    bitrate => Plugins::SpotOn::Plugin->_bitrateForClient($client) . 'k',
                    play    => $browseUrl,
                };
            }
            return { %$connect_meta, play => $browseUrl };
        }
        # No cached spotifyUri — fall through to async re-fetch path below
    }

    # Normalize: cache is keyed on spoton://track:ID but LMS may pass spoton:track:ID
    my $canonical = $url;
    if ($canonical && $canonical =~ m{^spoton:(?!//)}) {
        $canonical =~ s{^spoton:}{spoton://};
    }

    my $meta = $cache->get('spoton_meta_' . md5_hex($canonical));

    # Fallback: try original URL if normalization didn't help
    if (!$meta && $canonical ne $url) {
        $meta = $cache->get('spoton_meta_' . md5_hex($url));
    }

    # D-03, D-04, D-05: cache miss — return placeholder immediately, fire async re-fetch
    unless ($meta) {
        _asyncRefetch($class, $client, $url, $canonical);
        return _placeholderMeta($url);
    }

    if ($client) {
        require Plugins::SpotOn::Plugin;
        return { %$meta,
            type    => Plugins::SpotOn::Plugin->_typeString($client, 'Browse'),
            bitrate => Plugins::SpotOn::Plugin->_bitrateForClient($client) . 'k',
        };
    }

    return $meta;
}

sub trackInfoURL {
    my ($class, $client, $url) = @_;

    my ($trackId) = ($url // '') =~ m{spoton:(?://)?track:([A-Za-z0-9]+)};
    return unless $trackId;

    my $meta = $class->getMetadataFor($client, $url) || {};

    require Plugins::SpotOn::Plugin;
    my $accountId = Plugins::SpotOn::Plugin::_getAccountId($client);

    my @items;
    if ($accountId) {
        push @items, {
            name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_LIKE'),
            url         => \&Plugins::SpotOn::Plugin::_toggleLike,
            passthrough => [{ trackUri => "spotify:track:$trackId", accountId => $accountId }],
            type        => 'link',
        };
    }

    return {
        name  => $meta->{title} || $url,
        type  => 'opml',
        items => \@items,
    };
}

# _placeholderMeta($url)
# Returns minimal metadata for immediate display while async re-fetch is in progress.
# D-03: cache miss returns placeholder, not empty hashref.
sub _placeholderMeta {
    my ($url) = @_;
    my $title = ($url && $url =~ m{spoton://track:}) ? 'Loading...' : '';
    return {
        cover => '/html/images/cover.png',
        icon  => '/html/images/cover.png',
        title => $title,
    };
}

# _asyncRefetch($class, $client, $url, $canonical)
# Fires an async API::Client->getTrack call for a cache-miss URL.
# D-04: extracts track ID from Browse URL or from cached spotifyUri for Connect URLs.
# D-05: debounce via %_pendingRefetch — one in-flight re-fetch per URL.
# Pitfall 4: delete from debounce hash is the FIRST action in the callback.
# Pitfall 3: Connect re-fetch stores result under Browse URL cache key.
sub _asyncRefetch {
    my ($class, $client, $url, $canonical) = @_;

    # D-05: debounce — skip if already fetching this URL
    return unless $url;
    return if $_pendingRefetch{$url};

    # Extract track ID from Browse URL or from cached connect entry's spotifyUri
    my $trackId;
    if ($canonical && $canonical =~ m{spoton://track:([A-Za-z0-9]+)}) {
        $trackId = $1;
    } elsif ($url && $url =~ m{spoton://connect-}) {
        my $connect_meta = $cache->get('spoton_meta_' . md5_hex($url));
        if ($connect_meta && $connect_meta->{spotifyUri}
            && $connect_meta->{spotifyUri} =~ m/^spotify:track:([A-Za-z0-9]+)$/) {
            $trackId = $1;
        }
    }
    return unless $trackId;

    # Resolve accountId — T-11-03: only alphanumeric track IDs reach here
    my $accountId;
    if ($client) {
        $accountId = $prefs->client($client)->get('activeAccount')
                  || $prefs->get('activeAccount')
                  || '';
    } else {
        $accountId = $prefs->get('activeAccount') || '';
    }

    # D-05: mark in-flight
    $_pendingRefetch{$url} = 1;

    require Plugins::SpotOn::API::Client;

    Plugins::SpotOn::API::Client->getTrack($accountId, $trackId, sub {
        my ($trackInfo) = @_;

        # Pitfall 4: ALWAYS clear debounce first — even on error
        delete $_pendingRefetch{$url};

        return unless $trackInfo && $trackInfo->{name};

        my $title    = $trackInfo->{name};
        my $artist   = join(', ', map { $_->{name} } @{ $trackInfo->{artists} || [] });
        my $album    = ($trackInfo->{album} || {})->{name} || '';
        my $duration = ($trackInfo->{duration_ms} || 0) / 1000;
        my $cover    = _largestImage(($trackInfo->{album} || {})->{images})
                    || '/html/images/cover.png';

        my %new_meta = (
            title    => $title,
            artist   => $artist,
            album    => $album,
            duration => $duration,
            cover    => $cover,
            icon     => $cover,
        );

        # Pitfall 3: for Connect URLs, store under Browse URL key so future lookups find it
        my $cacheUrl = ($url && $url =~ m{spoton://connect-})
            ? "spoton://track:$trackId"
            : $canonical;

        $cache->set('spoton_meta_' . md5_hex($cacheUrl), \%new_meta, 604800);

        # Notify LMS to refresh NowPlaying display
        if ($client) {
            require Slim::Control::Request;
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        }
    });
}

# _largestImage($images_arrayref)
# Returns the URL of the largest image (by width) from a Spotify images array.
# Returns '' if the array is empty or undef.
# Local copy — avoids importing from Connect.pm (Pitfall 1).
sub _largestImage {
    my ($images) = @_;
    return '' unless ref $images eq 'ARRAY' && @{$images};
    my ($largest) = sort { ($b->{width} || 0) <=> ($a->{width} || 0) } @{$images};
    return $largest->{url} || '';
}

1;

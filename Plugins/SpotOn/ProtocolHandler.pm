package Plugins::SpotOn::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Versions;
use Slim::Utils::Cache;
use Slim::Utils::Network;
use Digest::MD5 qw(md5_hex);

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();
my $CRLF  = "\x0d\x0a";

sub contentType { 'son' }

sub isRemote    { 1 }

# getFormatForURL($class, $url)
# Returns content type for a given URL:
# - 'soc' for Connect URLs (spotify://connect-*)
# - 'son' for single-track Browse URLs (default)
sub getFormatForURL {
    my ($class, $url) = @_;
    return 'soc' if $url && $url =~ m{spotify://connect-};
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

    if ($url =~ m{spotify://connect-}) {
        require Plugins::SpotOn::Connect::DaemonManager;
        my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client);
        if ($helper && $helper->_streamMode) {
            return 'soc';  # Connect: always 'soc', independent of streamFormat
        }
    }

    # Browse mode: OGG passthrough if explicitly selected, otherwise PCM/son pipeline
    return 'ogg' if $fmt eq 'ogg';
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
# (b) D-06 Sync-group proxy: spotify://connect-* URL for synced players
#     → substitute HTTP URL so all sync members get audio from binary's HTTP server
#
# Note: DaemonManager require is on-demand (not at top level) per plan acceptance criteria.
sub new {
    my ($class, $args) = @_;

    my $url = $args->{url} || '';

    # (a) D-08: spotify:// (Browse/single-track) URL while Connect is active
    # Stop the Connect daemon so Browse can proceed cleanly.
    if ($url =~ m{^spotify://(?!connect-)}) {
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

    # (b) D-06: spotify://connect-* URL — substitute HTTP stream URL for sync-group proxy
    if ($url =~ m{spotify://connect-}) {
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

sub isRepeatingStream {
    my (undef, $song) = @_;
    return unless $song;
    my $url = $song->track->url || '';
    return $url =~ m{spotify://connect-} ? 1 : 0;
}

sub canSeek {
    my ($class, $client) = @_;
    if ($client) {
        my $song = $client->playingSong();
        my $url = $song ? ($song->track->url || '') : '';
        return 0 if $url =~ m{spotify://connect-};
    }
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub canTranscodeSeek {
    my ($class, $client) = @_;
    if ($client) {
        my $song = $client->playingSong();
        my $url = $song ? ($song->track->url || '') : '';
        return 0 if $url =~ m{spotify://connect-};
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
    if ($url && $url =~ m{spotify://connect-} && $client) {
        $client = $client->master if $client->can('master');
        my $song = $client->playingSong();
        if ($song && (my $info = $song->pluginData('info'))) {
            return $info;
        }
    }

    return $cache->get('spoton_meta_' . md5_hex($url)) || {};
}

1;

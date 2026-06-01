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

    if ($url =~ m{spotify://connect-}) {
        require Plugins::SpotOn::Connect::DaemonManager;
        my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client);
        if ($helper && $helper->_streamMode) {
            return 'soc';
        }
    }

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

    require Plugins::SpotOn::Connect::DaemonManager;
    my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client);
    return 0 unless $helper && $helper->_streamMode && $helper->_streamPort;

    return 0 if $client->isSynced();

    my $host = Slim::Utils::Network::serverAddr();
    return 'http://' . $host . ':' . $helper->_streamPort . '/stream';
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

# canSeek($class, $client)
# Returns 0 when in Connect mode — seeking is handled via startOffset (CON-13).
# Returning 0 prevents LMS from using _JumpToTime which would restart the HTTP stream.
sub canSeek {
    my ($class, $client) = @_;
    if ($client) {
        require Plugins::SpotOn::Connect;
        return 0 if Plugins::SpotOn::Connect->isSpotifyConnect($client);
    }
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

# canTranscodeSeek($class, $client)
# Same Connect guard as canSeek.
sub canTranscodeSeek {
    my ($class, $client) = @_;
    if ($client) {
        require Plugins::SpotOn::Connect;
        return 0 if Plugins::SpotOn::Connect->isSpotifyConnect($client);
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

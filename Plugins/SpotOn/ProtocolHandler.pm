package Plugins::SpotOn::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Versions;
use Slim::Utils::Cache;
use Digest::MD5 qw(md5_hex);

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

sub contentType    { 'son' }

sub isRemote       { 1 }

# CRITICAL: forces LMS to use the transcoding pipeline — never direct-stream Spotify
sub canDirectStream { 0 }

# Default content type: 'son' — LMS uses this as input type in transcoding profile key
# (e.g. son-flc-*-*). Must match formatOverride return value (STR-01, STR-02).
sub getFormatForURL { return 'son' }

sub formatOverride {
    my ($class, $song) = @_;

    my $client = $song->master;

    # Inject runtime parameters (bitrate, cache dir, helper name, normalization) into
    # commandTable before format selection (D-01, Pattern 1). Must happen first.
    # Passthrough-guard (STR-05) runs inside updateTranscodingTable.
    require Plugins::SpotOn::Plugin;
    Plugins::SpotOn::Plugin->updateTranscodingTable($client);

    # Return 'son' — the INPUT content type, not the output format.
    # LMS Song.pm constructs the transcoding profile key as:
    #   formatOverride-outputFormat-*-*  (e.g. son-flc-*-*)
    # Returning 'flc' here created 'flc-flc-*-*' which has no matching profile.
    # 'son' correctly matches son-flc-*-* and son-ogg-*-* in custom-convert.conf.
    return 'son';
}

# Seeking requires LMS 7.9.1+
sub canSeek          { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }
sub canTranscodeSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
}

# getMetadataFor($class, $client, $url)
# Returns cached track metadata for NowPlaying display (artwork, title, artist, album,
# duration, bitrate, type). Cache is populated by Plugin.pm _trackItem/_albumTrackItem
# when building OPML items. Cache key: 'spoton_meta_' + md5_hex(url). TTL: 3600s.
# Per STR-03: LMS calls this to populate the NowPlaying display.
sub getMetadataFor {
    my ($class, $client, $url) = @_;
    return $cache->get('spoton_meta_' . md5_hex($url)) || {};
}

1;

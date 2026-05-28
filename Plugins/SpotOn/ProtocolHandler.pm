package Plugins::SpotOn::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Player::CapabilitiesHelper;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

sub contentType    { 'son' }

sub isRemote       { 1 }

# CRITICAL: forces LMS to use the transcoding pipeline — never direct-stream Spotify
sub canDirectStream { 0 }

# Default pipeline: son->flc (FLAC output)
sub getFormatForURL { 'flc' }

sub formatOverride {
    my ($class, $song) = @_;

    my $client = $song->master;

    # Inject runtime parameters (bitrate, cache dir, helper name, normalization) into
    # commandTable before format selection (D-01, Pattern 1). Must happen first.
    require Plugins::SpotOn::Plugin;
    Plugins::SpotOn::Plugin->updateTranscodingTable($client);

    # Query player format capabilities
    my @formats = Slim::Player::CapabilitiesHelper::supportedFormats($client);

    # OGG-Direct: only when player supports OGG natively AND binary has passthrough
    # capability (STR-05, A2-Mitigation guard per RESEARCH.md Open Question 1 resolution)
    if (grep { $_ eq 'ogg' } @formats) {
        require Plugins::SpotOn::Helper;
        if (Plugins::SpotOn::Helper->getCapability('passthrough')) {
            return 'ogg';
        }
    }

    # FLAC: default fallback for all modern players (D-04, STR-02)
    return 'flc';
}

# Seeking requires LMS 7.9.1+
sub canSeek          { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }
sub canTranscodeSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
}

1;

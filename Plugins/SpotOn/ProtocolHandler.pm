package Plugins::SpotOn::ProtocolHandler;

use strict;

use base qw(Slim::Formats::RemoteStream);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

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
    # Phase 4: updateTranscodingTable will be called here
    return 'son';
}

# Seeking requires LMS 7.9.1+
sub canSeek          { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }
sub canTranscodeSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
}

1;

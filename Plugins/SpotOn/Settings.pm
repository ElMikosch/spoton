package Plugins::SpotOn::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::SpotOn::Helper;

use constant SETTINGS_URL => 'plugins/SpotOn/settings/basic.html';

my $prefs = preferences('plugin.spoton');

sub new {
    my $class = shift;
    return $class->SUPER::new(@_);
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTON_NAME');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs {
    return ($prefs, 'bitrate', 'binary');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    # Binary-Status an Template uebergeben
    $paramRef->{helperMissing} = string('PLUGIN_SPOTON_BINARY_MISSING') unless $helperPath;
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        my $bitrate = $paramRef->{'pref_bitrate'};
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);
    }

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;

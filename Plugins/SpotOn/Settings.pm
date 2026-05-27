package Plugins::SpotOn::Settings;

use strict;
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
        $prefs->set('bitrate', $paramRef->{'pref_bitrate'} || 320);
        # 'binary' wird von Slim::Web::Settings automatisch gespeichert (via prefs() Methode)
    }

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;

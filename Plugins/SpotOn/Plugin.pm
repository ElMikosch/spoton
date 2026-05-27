package Plugins::SpotOn::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use File::Basename;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

my $prefs = preferences('plugin.spoton');

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
        bitrate => 320,
        binary  => '',    # custom binary override (LMS-10, Phase 6)
    });

    require Plugins::SpotOn::Helper;
    Plugins::SpotOn::Helper->init();

    $VERSION = $class->_pluginDataFor('version');

    Slim::Player::ProtocolHandlers->registerHandler(
        'spotify',
        'Plugins::SpotOn::ProtocolHandler'
    );

    if (main::WEBUI) {
        require Plugins::SpotOn::Settings;
        Plugins::SpotOn::Settings->new();
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

    # Phase 1 Placeholder
    $callback->({
        items => [{
            name => cstring($client, 'PLUGIN_SPOTON_NAME'),
            type => 'textarea',
        }]
    });
}

1;

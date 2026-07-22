package Plugins::SpotOn::HomeExtras;

use strict;

Plugins::SpotOn::HomeExtraRecentlyPlayed->initPlugin();
Plugins::SpotOn::HomeExtraTopTracks->initPlugin();

1;

package Plugins::SpotOn::HomeExtraBase;

use strict;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

# initPlugin(%args)
# %args: feed (coderef), tag (string), title (string), subtitle (string, optional)
# needsPlayer => 1 is required because the feed coderefs (_recentlyPlayedFeed,
# _topTracksFeed) resolve the active Spotify account via _getAccountId($client),
# which is a per-player preference.
sub initPlugin {
    my ($class, %args) = @_;

    my $tag = $args{tag};

    $class->SUPER::initPlugin(
        feed => $args{feed},
        tag  => "SpotOnExtras${tag}",
        extra => {
            title       => $args{title},
            subtitle    => $args{subtitle},
            icon        => Plugins::SpotOn::Plugin->_pluginDataFor('icon'),
            needsPlayer => 1,
        },
    );
}

1;

package Plugins::SpotOn::HomeExtraRecentlyPlayed;

use strict;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my ($class, %args) = @_;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_RECENTLY_PLAYED',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_recentlyPlayedFeed,
        tag      => 'RecentlyPlayed',
    );
}

1;

package Plugins::SpotOn::HomeExtraTopTracks;

use strict;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my ($class, %args) = @_;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_TOP_TRACKS',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_topTracksFeed,
        tag      => 'TopTracks',
    );
}

1;

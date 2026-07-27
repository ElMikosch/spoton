package Plugins::SpotOn::HomeExtras;

use strict;
use warnings;

Plugins::SpotOn::HomeExtraRecentlyPlayed->initPlugin();
Plugins::SpotOn::HomeExtraTopTracks->initPlugin();
Plugins::SpotOn::HomeExtraMadeForYou->initPlugin();
Plugins::SpotOn::HomeExtraMainMenu->initPlugin();
Plugins::SpotOn::HomeExtraPlaylists->initPlugin();

1;

package Plugins::SpotOn::HomeExtraBase;

use strict;
use warnings;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

my %_feedCache;

sub initPlugin {
    my ($class, %args) = @_;

    my $tag = $args{tag};
    my $origFeed = $args{feed};

    # Wrap feed: filter textarea items that render as junk cards in MS
    # scrolled rows (WR-01), and memoize for 60s to avoid hitting the
    # uncached recently-played endpoint on every home-screen refresh (WR-02).
    $args{feed} = sub {
        my ($client, $cb, $feedArgs) = @_;

        my $cacheKey = $tag . '_' . ($client ? $client->id : '');
        my $cached = $_feedCache{$cacheKey};

        if ($cached && time() - $cached->{ts} < 60) {
            $cb->($cached->{result});
            return;
        }

        $origFeed->($client, sub {
            my $result = shift;
            my @items = grep { ($_->{type} || '') ne 'textarea' }
                        @{ $result->{items} || [] };
            my $filtered = { %$result, items => \@items };
            $_feedCache{$cacheKey} = { ts => time(), result => $filtered };
            $cb->($filtered);
        }, $feedArgs);
    };

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
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

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
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_TOP_TRACKS',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_topTracksFeed,
        tag      => 'TopTracks',
    );
}

1;

package Plugins::SpotOn::HomeExtraMadeForYou;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_MADE_FOR_YOU',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_madeForYouFeed,
        tag      => 'MadeForYou',
    );
}

1;

package Plugins::SpotOn::HomeExtraMainMenu;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_MAIN_MENU',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::handleFeed,
        tag      => 'MainMenu',
    );
}

1;

package Plugins::SpotOn::HomeExtraPlaylists;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_PLAYLISTS',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_userPlaylistsFeed,
        tag      => 'Playlists',
    );
}

1;

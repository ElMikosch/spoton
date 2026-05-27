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

    require Plugins::SpotOn::API::TokenManager;

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

        # Account add (D-07).
        # addAccount uses a blocking backtick spawn and invokes $cb synchronously.
        # $accountId and $err are captured from the callback before the if-blocks below.
        # IMPORTANT: if addAccount is ever made truly async, the code below must move
        # into the callback body.
        if ($paramRef->{addAccount}) {
            my $username = $paramRef->{username} // '';
            my $password = $paramRef->{password} // '';
            $username =~ s/^\s+|\s+$//g;
            $password =~ s/^\s+|\s+$//g;

            if ($username && $password) {
                my ($accountId, $err);
                Plugins::SpotOn::API::TokenManager->addAccount($username, $password, sub {
                    ($accountId, $err) = @_;
                });
                if ($err) {
                    $paramRef->{authError} = $err;
                } elsif ($accountId) {
                    $prefs->set('activeAccount', $accountId)
                        unless $prefs->get('activeAccount');
                }
            }
        }

        # Account remove (CR-03, WR-03).
        # WR-03: validate that removeId is an 8-char hex string that actually
        # exists in the accounts pref before acting on it.  This prevents a
        # crafted POST with e.g. removeAccount=../../etc from reaching _cacheDir
        # and potentially deleting directories outside the SpotOn data dir.
        # CR-03: determine the new activeAccount BEFORE calling removeAccount,
        # because removeAccount clears activeAccount to '' before returning —
        # checking it afterwards would always yield '' and never auto-select a
        # replacement.
        if (my $removeId = $paramRef->{removeAccount}) {
            my $accounts = $prefs->get('accounts') || {};
            if (exists $accounts->{$removeId} && $removeId =~ /\A[0-9a-f]{8}\z/) {
                my $newActive;
                if (($prefs->get('activeAccount') || '') eq $removeId) {
                    # Removed account was active — pick a replacement from the
                    # remaining accounts (sorted for determinism).
                    my @remaining = sort grep { $_ ne $removeId } keys %{$accounts};
                    $newActive = @remaining ? $remaining[0] : '';
                }

                Plugins::SpotOn::API::TokenManager->removeAccount($removeId);

                # Apply the pre-computed replacement if one was needed.
                # (removeAccount already set activeAccount to '' if it was active;
                # we overwrite that '' with the proper replacement here.)
                if (defined $newActive) {
                    $prefs->set('activeAccount', $newActive);
                }
            }
        }

        # Account switch (WR-04).
        # Validate that switchId is a known account before setting it as active.
        # Without this check an attacker with a valid LMS session could set
        # activeAccount to an arbitrary string, which could confuse code that
        # reads the preference and assumes it points to a real account.
        if (my $switchId = $paramRef->{switchAccount}) {
            my $accounts = $prefs->get('accounts') || {};
            if (exists $accounts->{$switchId}) {
                $prefs->set('activeAccount', $switchId);
            }
        }
    }

    # Pass account data to template for all requests
    $paramRef->{accounts}      = $prefs->get('accounts') || {};
    $paramRef->{activeAccount} = $prefs->get('activeAccount') || '';

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;

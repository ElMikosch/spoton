#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $stub_dir = tempdir(CLEANUP => 1);

# Helper: write a stub Perl module
sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Slim::Utils::Log -- records calls so tests can assert log severity
# per cause (D-03/D-04/D-05 must use distinct severities).
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @calls;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @calls, ['info',  $_[1]] }
sub warn  { push @calls, ['warn',  $_[1]] }
sub error { push @calls, ['error', $_[1]] }
sub debug { push @calls, ['debug', $_[1]] }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
my %_store;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences {
    my $ns = ($_[0] eq 'Slim::Utils::Prefs') ? $_[1] : $_[0];
    return bless { _ns => $ns }, 'Slim::Utils::Prefs';
}
sub get    { $_store{$_[0]->{_ns}}{$_[1]} }
sub set    { $_store{$_[0]->{_ns}}{$_[1]} = $_[2] }
sub client { return bless { _ns => $_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }
1;
END

# Stub: Slim::Utils::Cache -- exposes remove()/clear() for test resets
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
sub head { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

BEGIN {
    no warnings 'redefine';
    # INFOLOG must be true here (unlike other t/*.t files) -- this file
    # specifically asserts that the D-03/D-05 causes emit a distinct INFO
    # log line, and WebPlayer.pm gates info() calls behind
    # `main::INFOLOG && $log->info(...)` like the rest of the codebase.
    *main::INFOLOG = sub () { 1 };
}

BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

# Install preferences()/logger() into this test script's own namespace too
# (WebPlayer.pm gets them via its own `use`; the test needs them directly
# to seed accounts prefs and inspect Slim::Utils::Log::@calls).
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();

require_ok('Plugins::SpotOn::API::WebPlayer')
    or BAIL_OUT('Failed to load WebPlayer.pm');

my $WP = 'Plugins::SpotOn::API::WebPlayer';

sub reset_state {
    Slim::Utils::Cache->new()->clear();
    preferences('plugin.spoton')->set('accounts', {});
    @Slim::Utils::Log::calls = ();
}

# ------------------------------------------------------------
# 1. No sp_dc stored -> empty (D-03), distinct INFO log
# ------------------------------------------------------------
{
    reset_state();
    is($WP->state('acct_empty'), 'empty', "state(): no sp_dc stored -> 'empty' (D-03)");

    my @info = grep { $_->[0] eq 'info' && $_->[1] =~ /no sp_dc configured/ } @Slim::Utils::Log::calls;
    ok(scalar(@info) >= 1, "state(): 'empty' cause logs a distinct INFO line (D-03)");
}

# ------------------------------------------------------------
# 2. sp_dc present + cached negative state 'secrets_down' -> secrets_down (D-05)
# ------------------------------------------------------------
{
    reset_state();
    $WP->storeSpDc('acct_secrets_down', 'AQDxSOMECOOKIEVALUE');
    Slim::Utils::Cache->new()->set('spoton_wp_state_acct_secrets_down', 'secrets_down', 300);

    is($WP->state('acct_secrets_down'), 'secrets_down',
        "state(): sp_dc present + cached secrets_down -> 'secrets_down' (D-05)");
}

# ------------------------------------------------------------
# 3. sp_dc present + cached negative state 'expired' -> expired (D-04), WARN log
# ------------------------------------------------------------
{
    reset_state();
    $WP->storeSpDc('acct_expired', 'AQDxSOMECOOKIEVALUE');
    @Slim::Utils::Log::calls = (); # storeSpDc's own INFO log is not under test here
    Slim::Utils::Cache->new()->set('spoton_wp_state_acct_expired', 'expired', 300);

    is($WP->state('acct_expired'), 'expired',
        "state(): sp_dc present + cached expired -> 'expired' (D-04)");
}

# ------------------------------------------------------------
# 4. sp_dc present + token cached -> valid (trumps a stale negative state)
# ------------------------------------------------------------
{
    reset_state();
    $WP->storeSpDc('acct_valid', 'AQDxSOMECOOKIEVALUE');
    Slim::Utils::Cache->new()->set('spoton_wp_state_acct_valid', 'secrets_down', 300);
    Slim::Utils::Cache->new()->set('spoton_wp_token_acct_valid',
        { access_token => 'tok', client_token => 'ctok' }, 3300);

    is($WP->state('acct_valid'), 'valid',
        "state(): a cached token wins over a stale negative state -> 'valid'");
}

# ------------------------------------------------------------
# 5. sp_dc present, nothing cached -> valid (default, "innocent until proven guilty")
# ------------------------------------------------------------
{
    reset_state();
    $WP->storeSpDc('acct_fresh', 'AQDxSOMECOOKIEVALUE');

    is($WP->state('acct_fresh'), 'valid',
        'state(): fresh sp_dc with no cached negative state defaults to valid');
}

# ------------------------------------------------------------
# Distinct log severities: expired uses WARN (not INFO)
# ------------------------------------------------------------
{
    reset_state();
    Plugins::SpotOn::API::WebPlayer::_setState('acct_sev', 'expired');
    my @warn = grep { $_->[0] eq 'warn' && $_->[1] =~ /sp_dc expired/ } @Slim::Utils::Log::calls;
    ok(scalar(@warn) >= 1, '_setState: expired cause logs at WARN severity (D-04)');

    reset_state();
    Plugins::SpotOn::API::WebPlayer::_setState('acct_sev2', 'secrets_down');
    my @info = grep { $_->[0] eq 'info' && $_->[1] =~ /TOTP secrets unavailable/ } @Slim::Utils::Log::calls;
    ok(scalar(@info) >= 1, '_setState: secrets_down cause logs at INFO severity (D-05)');
}

# ------------------------------------------------------------
# statusSnapshot: no token/secret/cookie values, only masked preview
# ------------------------------------------------------------
{
    reset_state();
    $WP->storeSpDc('acct_snap', 'AQDxSOMECOOKIEVALUE');

    my $snap = $WP->statusSnapshot('acct_snap');
    is($snap->{state}, 'valid', 'statusSnapshot: state field reflects state()');
    is($snap->{spDcPresent}, 1, 'statusSnapshot: spDcPresent is 1 when sp_dc is stored');
    is($snap->{spDcMasked}, 'AQDx****', 'statusSnapshot: spDcMasked is a masked preview, never the raw value');

    my $json = Plugins::SpotOn::API::WebPlayer::to_json($snap);
    unlike($json, qr/AQDxSOMECOOKIEVALUE/, 'statusSnapshot: serialized snapshot never contains the raw sp_dc value');
    unlike($json, qr/access_token|client_token/, 'statusSnapshot: serialized snapshot exposes no token fields');
}

{
    reset_state();
    my $snap = $WP->statusSnapshot('acct_no_spdc');
    is($snap->{state}, 'empty', 'statusSnapshot: empty state when no sp_dc is stored');
    is($snap->{spDcPresent}, 0, 'statusSnapshot: spDcPresent is 0 when no sp_dc is stored');
    is($snap->{spDcMasked}, '', 'statusSnapshot: spDcMasked is empty string when no sp_dc is stored');
}

done_testing();

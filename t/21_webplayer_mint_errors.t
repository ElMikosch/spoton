#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once'; # package-qualified vars (Log::calls, SimpleAsyncHTTP::next_mode) referenced once per scope
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
# per branch (CR-02: transient failures must not log/behave like D-04).
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

# Stub: Slim::Utils::Cache -- exposes clear() so each scenario starts clean
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

# Stub: Slim::Networking::SimpleAsyncHTTP -- captures the success/error
# callbacks passed to new(), then get() immediately drives the scenario
# selected via the package variable $next_mode (WR-04 regression coverage
# for _requestToken's HTTP dispatch, the exact code path containing CR-02).
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our $next_mode = '';
sub new {
    my ($class, $success, $error, $opts) = @_;
    return bless { success => $success, error => $error }, $class;
}
sub get {
    my ($self, $url, @rest) = @_;
    if ($next_mode eq 'error_500') {
        my $resp = bless { code => 500 }, 'Slim::Networking::MockResponse';
        $self->{error}->($self, 'Internal Server Error', $resp);
    } elsif ($next_mode eq 'error_401') {
        my $resp = bless { code => 401 }, 'Slim::Networking::MockResponse';
        $self->{error}->($self, 'Unauthorized', $resp);
    } elsif ($next_mode eq 'error_400') {
        my $resp = bless { code => 400 }, 'Slim::Networking::MockResponse';
        $self->{error}->($self, 'Bad Request', $resp);
    } elsif ($next_mode eq 'success_bad_json') {
        my $mock = bless { content => 'not-valid-json' }, 'Slim::Networking::MockResponse';
        $self->{success}->($mock);
    } elsif ($next_mode eq 'success_valid') {
        my $mock = bless {
            content => '{"accessToken":"tok123","accessTokenExpirationTimestampMs":"99999999999999","clientId":"cid123"}'
        }, 'Slim::Networking::MockResponse';
        $self->{success}->($mock);
    }
    return $self;
}
sub head { return $_[0]; }
sub post { return $_[0]; }

package Slim::Networking::MockResponse;
sub code    { $_[0]->{code} }
sub can     { 1 }
sub content { $_[0]->{content} }
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
    # INFOLOG must be true here -- WebPlayer.pm gates info() calls behind
    # `main::INFOLOG && $log->info(...)`.
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

# Monkeypatch _clientToken so the stub's 'success_valid' scenario (unused
# by Tests A-D below, kept for stub completeness) never needs a second
# HTTP dispatch mode through the same SimpleAsyncHTTP stub.
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${WP}::_clientToken"} = sub {
        my ($class, $clientId, $cb) = @_;
        $cb->('fake_client_token');
    };
}

my $FIXED_SECRET = { version => 1, cipher => [10, 20, 30, 40, 50, 60, 70, 80, 90, 100] };
my $FIXED_EPOCH  = 1_700_000_000;
my $SPDC         = 'AQDxSOMECOOKIEVALUE';

sub reset_state {
    my ($accountId) = @_;
    Slim::Utils::Cache->new()->clear();
    preferences('plugin.spoton')->set('accounts', {});
    $WP->storeSpDc($accountId, $SPDC) if $accountId;
    @Slim::Utils::Log::calls = (); # storeSpDc's own INFO log is not under test here
}

sub run_mint {
    my ($accountId, $mode) = @_;
    $Slim::Networking::SimpleAsyncHTTP::next_mode = $mode;
    my ($token, $reason);
    $WP->_requestToken($accountId, $SPDC, $FIXED_SECRET, $FIXED_EPOCH, 0, sub {
        ($token, $reason) = @_;
    });
    return ($token, $reason);
}

# ------------------------------------------------------------
# Test A: 500 HTTP error -> state() NOT 'expired', reason 'mint_failed'
# ------------------------------------------------------------
{
    my $acct = 'acct_500';
    reset_state($acct);
    is($WP->state($acct), 'valid', "sanity: $acct starts valid before mint");

    my ($token, $reason) = run_mint($acct, 'error_500');
    ok(!defined $token, 'Test A: 500 error resolves with no token');
    is($reason, 'mint_failed', "Test A: 500 error resolve reason is 'mint_failed'");
    isnt($WP->state($acct), 'expired', "Test A: 500 error does NOT set state() to 'expired' (CR-02)");
}

# ------------------------------------------------------------
# Test B: unparseable JSON success body -> state() NOT 'expired', reason 'mint_failed'
# ------------------------------------------------------------
{
    my $acct = 'acct_badjson';
    reset_state($acct);
    is($WP->state($acct), 'valid', "sanity: $acct starts valid before mint");

    my ($token, $reason) = run_mint($acct, 'success_bad_json');
    ok(!defined $token, 'Test B: bad JSON resolves with no token');
    is($reason, 'mint_failed', "Test B: bad JSON resolve reason is 'mint_failed'");
    isnt($WP->state($acct), 'expired', "Test B: bad JSON does NOT set state() to 'expired' (CR-02)");
}

# ------------------------------------------------------------
# Test C: 401 HTTP error -> state() IS 'expired', reason 'expired'
# ------------------------------------------------------------
{
    my $acct = 'acct_401';
    reset_state($acct);
    is($WP->state($acct), 'valid', "sanity: $acct starts valid before mint");

    my ($token, $reason) = run_mint($acct, 'error_401');
    ok(!defined $token, 'Test C: 401 error resolves with no token');
    is($reason, 'expired', "Test C: 401 error resolve reason is 'expired'");
    is($WP->state($acct), 'expired', "Test C: 401 error DOES set state() to 'expired' (D-04)");
}

# ------------------------------------------------------------
# Test D: 400 HTTP error -> state() IS 'expired', reason 'expired'
# ------------------------------------------------------------
{
    my $acct = 'acct_400';
    reset_state($acct);
    is($WP->state($acct), 'valid', "sanity: $acct starts valid before mint");

    my ($token, $reason) = run_mint($acct, 'error_400');
    ok(!defined $token, 'Test D: 400 error resolves with no token');
    is($reason, 'expired', "Test D: 400 error resolve reason is 'expired'");
    is($WP->state($acct), 'expired', "Test D: 400 error DOES set state() to 'expired' (D-04)");
}

done_testing();

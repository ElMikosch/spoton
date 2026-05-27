#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Create a temporary directory for LMS stubs (CLEANUP on test exit)
my $stub_dir = tempdir(CLEANUP => 1);

# Cache dir for mock tests
my $cache_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module into the stub directory
# ============================================================
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

# ============================================================
# LMS Module Stubs (copied from t/07_token_manager.t)
# ============================================================

# Stub: Log::Log4perl::Logger
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Log::Log4perl
write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Slim::Utils::Log
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info  { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn  { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# Supports preferences('server')->get('httpport') returning 9000 for _buildRedirectUri
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir', httpport => 9000 } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    return bless { _ns => \$self->{_ns} . '_client_' . (\$client // 'default') }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache (in-memory, records TTL for inspection)
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

# Stub: Slim::Utils::Timers (records calls for inspection)
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_]; }
sub killTimers { push @kill_calls, [@_]; }
sub reset_calls { @set_calls = (); @kill_calls = (); }
1;
END

# Stub: Slim::Utils::Strings
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub string  { join(' ', grep { defined } @_[1..$#_]) }
sub cstring { join(' ', grep { defined } @_[1..$#_]) }
1;
END

# Stub: JSON::XS::VersionOneAndTwo (delegates to JSON::PP)
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# Stub: Time::HiRes (pass through to real Time::HiRes)
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: Slim::Plugin::OPMLBased (empty base class)
write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new        { bless {}, shift }
sub initPlugin { }
sub _pluginDataFor { }
sub AUTOLOAD   { }
sub can        { 1 }
1;
END

# Stub: Slim::Player::ProtocolHandlers
write_stub($stub_dir, 'Slim::Player::ProtocolHandlers', <<'END');
package Slim::Player::ProtocolHandlers;
sub registerHandler { }
1;
END

# Stub: Slim::Web::Settings
write_stub($stub_dir, 'Slim::Web::Settings', <<'END');
package Slim::Web::Settings;
sub new     { bless {}, shift }
sub handler { }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Slim::Web::HTTP::CSRF
write_stub($stub_dir, 'Slim::Web::HTTP::CSRF', <<'END');
package Slim::Web::HTTP::CSRF;
sub protectCommand { $_[1] }
sub protectName    { $_[1] }
sub protectURI     { $_[1] }
1;
END

# Stub: Slim::Formats::RemoteStream
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# ============================================================
# Additional stubs for Callback.pm
# ============================================================

# Stub: Slim::Networking::SimpleAsyncHTTP (same as in t/07_token_manager.t)
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our ($last_success_cb, $last_error_cb, $last_url, $last_body);
sub new {
    my ($class, $success, $error, $opts) = @_;
    $last_success_cb = $success;
    $last_error_cb   = $error;
    return bless {}, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    $last_url = $url;
    $last_body = $rest[-1] if @rest % 2 != 0;
    return $self;
}
sub get {
    my ($self, $url, @rest) = @_;
    $last_url = $url;
    return $self;
}
sub simulate_success {
    my ($class, $json_str) = @_;
    my $mock_http = bless { _content => $json_str }, 'Slim::Networking::MockHTTP';
    $last_success_cb->($mock_http) if $last_success_cb;
}
sub simulate_error {
    my ($class, $error_str) = @_;
    $last_error_cb->(undef, $error_str) if $last_error_cb;
}

package Slim::Networking::MockHTTP;
sub content { $_[0]->{_content} }
1;
END

# Stub: Slim::Web::Pages — records addPageFunction registrations
write_stub($stub_dir, 'Slim::Web::Pages', <<'END');
package Slim::Web::Pages;
our %registered;
sub addPageFunction { $registered{$_[1]} = $_[2] }
1;
END

# MockResponse is defined inline (not as a stub file) because it is not a
# Slim:: package and does not need to be loadable via require.
# It is used directly in tests via bless({}, 'MockResponse').
{
    package MockResponse;
    sub new          { bless {}, shift }
    sub content_type { $_[0]->{_ct} = $_[1] }
}

# Stub: Plugins::SpotOn::API::TokenManager — success mode by default
# Toggle $Plugins::SpotOn::API::TokenManager::_force_error to '...' for error mode
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our $_force_error  = undef;   # set to error string to simulate failure
our $_display_name = 'Test User';  # display name seeded into accounts pref on success
sub exchangeCode {
    my ($class, $code, $verifier, $clientId, $redirectUri, $cb) = @_;
    if ($_force_error) {
        $cb->(undef, $_force_error);
    } else {
        # Seed accounts hash with displayName BEFORE calling $cb so Callback.pm
        # can read it from prefs immediately in the success branch.
        Slim::Utils::Prefs->preferences('plugin.spoton')->set('accounts', {
            testacct => { displayName => $_display_name },
        });
        $cb->('testacct', undef);
    }
}
1;
END

# Stub: Crypt::OpenSSL::Random (deterministic for testing)
write_stub($stub_dir, 'Crypt::OpenSSL::Random', <<'END');
package Crypt::OpenSSL::Random;
sub random_bytes { 'x' x $_[1] }
1;
END

# Stub: URI
write_stub($stub_dir, 'URI', <<'END');
package URI;
sub new        { bless { _base => $_[1] }, $_[0] }
sub query_form { my $self = shift; $self->{_qf} = [@_] }
sub as_string  { 'https://accounts.spotify.com/authorize?mocked=1' }
sub query      { 'grant_type=authorization_code&code=testcode' }
1;
END

# ============================================================
# main:: constants (same as in t/07_token_manager.t)
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# ============================================================
# Add stub_dir and project_dir to @INC
# ============================================================
unshift @INC, $stub_dir, $project_dir;

# Load stub modules so their import() methods run and install functions
# into the calling namespace (preferences(), logger()).
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();

# ============================================================
# Tests: Settings/Callback.pm (skip if not yet created)
# ============================================================

my $callback_module = "$project_dir/Plugins/SpotOn/Settings/Callback.pm";

SKIP: {
    skip "Settings/Callback.pm not yet created", 15
        unless -f $callback_module;

    require_ok('Plugins::SpotOn::Settings::Callback')
        or BAIL_OUT("Failed to load Settings/Callback.pm");

    # --------------------------------------------------------
    # Test 1: D-06 Route registration via init()
    # --------------------------------------------------------
    {
        Plugins::SpotOn::Settings::Callback->init();
        ok(exists $Slim::Web::Pages::registered{'plugins/SpotOn/settings/callback'},
            'D-06: init() registers route at plugins/SpotOn/settings/callback via addPageFunction');
        isa_ok($Slim::Web::Pages::registered{'plugins/SpotOn/settings/callback'}, 'CODE',
            'D-06: registered handler is a code reference');
    }

    # --------------------------------------------------------
    # Test 2: D-08 Handler rejects missing/invalid state
    # (state not found in cache)
    # --------------------------------------------------------
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->clear();

        my @result_args;
        my $mock_response = bless {}, 'MockResponse';

        Plugins::SpotOn::Settings::Callback::handler(
            undef,
            { code => 'authcode123', state => 'nonexistent_state_xyz' },
            sub { @result_args = @_ },
            undef,
            $mock_response
        );

        ok(scalar(@result_args) > 0,
            'D-08: handler calls $callback when state is invalid');
        my $html_ref = $result_args[2];
        ok(defined $html_ref && ref($html_ref) eq 'SCALAR',
            'D-08: handler delivers HTML reference to callback for invalid state');
        if (defined $html_ref && ref($html_ref) eq 'SCALAR') {
            like($$html_ref, qr/invalid_state|Verbindung fehlgeschlagen/,
                'D-08: HTML body contains error indication for invalid state');
        } else {
            fail('D-08: HTML reference not available — cannot check content');
        }
    }

    # --------------------------------------------------------
    # Test 3: D-08 Handler rejects Spotify error parameter
    # (user clicked "Deny" on Spotify auth page)
    # --------------------------------------------------------
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->clear();

        my @result_args;
        my $mock_response = bless {}, 'MockResponse';

        Plugins::SpotOn::Settings::Callback::handler(
            undef,
            { error => 'access_denied', state => 'anystate' },
            sub { @result_args = @_ },
            undef,
            $mock_response
        );

        ok(scalar(@result_args) > 0,
            'D-08: handler calls $callback when Spotify returns error parameter');
        my $html_ref = $result_args[2];
        if (defined $html_ref && ref($html_ref) eq 'SCALAR') {
            like($$html_ref, qr/access_denied|Verbindung fehlgeschlagen/,
                'D-08: HTML body contains Spotify error string');
        } else {
            fail('D-08: HTML reference not available for Spotify error test');
        }
    }

    # --------------------------------------------------------
    # Test 4: D-08 Handler accepts valid state and exchanges code
    # Seed PKCE data in cache, call handler with valid state
    # --------------------------------------------------------
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->clear();

        # Seed PKCE data under the expected key
        $cache->set('spoton_pkce_validstate99', {
            code_verifier => 'test_verifier_abc',
            client_id     => 'test_client_id',
            redirect_uri  => 'http://127.0.0.1:9000/plugins/SpotOn/settings/callback',
        }, 600);

        # Reset TokenManager to success mode
        $Plugins::SpotOn::API::TokenManager::_force_error = undef;

        my @result_args;
        my $mock_response = bless {}, 'MockResponse';

        Plugins::SpotOn::Settings::Callback::handler(
            undef,
            { code => 'valid_auth_code', state => 'validstate99' },
            sub { @result_args = @_ },
            undef,
            $mock_response
        );

        ok(scalar(@result_args) > 0,
            'D-08: handler calls $callback when state and code are valid');
        my $html_ref = $result_args[2];
        if (defined $html_ref && ref($html_ref) eq 'SCALAR') {
            like($$html_ref, qr/Erfolgreich|verbunden/i,
                'D-08: HTML body contains success message after valid code exchange');
            like($$html_ref, qr/Verbunden als:.*Test User/s,
                'SC-2: success page shows display name');
        } else {
            fail('D-08: HTML reference not available for success test');
            fail('SC-2: HTML reference not available for display name test');
        }
    }

    # --------------------------------------------------------
    # Test 5: T-02.1-02 State consumed after use (one-time use, anti-replay)
    # Verify PKCE cache entry is deleted after successful validation
    # --------------------------------------------------------
    {
        # After test 4, the state 'validstate99' should have been consumed
        my $cache = Slim::Utils::Cache->new();
        ok(!defined $cache->get('spoton_pkce_validstate99'),
            'T-02.1-02: PKCE state cache entry consumed after handler execution (anti-replay)');
    }

    # --------------------------------------------------------
    # Test 6: Handler renders error HTML when TokenManager->exchangeCode fails
    # --------------------------------------------------------
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->clear();

        # Seed fresh PKCE data
        $cache->set('spoton_pkce_failstate', {
            code_verifier => 'fail_verifier',
            client_id     => 'fail_client',
            redirect_uri  => 'http://127.0.0.1:9000/plugins/SpotOn/settings/callback',
        }, 600);

        # Force TokenManager to return an error
        $Plugins::SpotOn::API::TokenManager::_force_error = 'token_exchange_error';

        my @result_args;
        my $mock_response = bless {}, 'MockResponse';

        Plugins::SpotOn::Settings::Callback::handler(
            undef,
            { code => 'bad_code', state => 'failstate' },
            sub { @result_args = @_ },
            undef,
            $mock_response
        );

        my $html_ref = $result_args[2];
        if (defined $html_ref && ref($html_ref) eq 'SCALAR') {
            like($$html_ref, qr/Verbindung fehlgeschlagen|token_exchange_error/,
                'D-08: HTML body contains error when TokenManager->exchangeCode fails');
        } else {
            fail('D-08: HTML reference not available for TokenManager error test');
        }

        # Reset for subsequent tests
        $Plugins::SpotOn::API::TokenManager::_force_error = undef;
    }

    # --------------------------------------------------------
    # Test 7: Success page omits "Verbunden als" when displayName is empty
    # --------------------------------------------------------
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->clear();

        # Seed PKCE data
        $cache->set('spoton_pkce_emptyname', {
            code_verifier => 'empty_verifier',
            client_id     => 'empty_client',
            redirect_uri  => 'http://127.0.0.1:9000/plugins/SpotOn/settings/callback',
        }, 600);

        # Seed accounts with empty displayName
        Slim::Utils::Prefs->preferences('plugin.spoton')->set('accounts', {
            testacct => { displayName => '' },
        });

        # Override TokenManager to NOT re-seed accounts (use the empty name above)
        $Plugins::SpotOn::API::TokenManager::_display_name = '';

        my @result_args;
        my $mock_response = bless {}, 'MockResponse';

        Plugins::SpotOn::Settings::Callback::handler(
            undef,
            { code => 'empty_name_code', state => 'emptyname' },
            sub { @result_args = @_ },
            undef,
            $mock_response
        );

        my $html_ref = $result_args[2];
        if (defined $html_ref && ref($html_ref) eq 'SCALAR') {
            like($$html_ref, qr/Erfolgreich/i,
                'SC-2: success page renders even when displayName is empty');
            unlike($$html_ref, qr/Verbunden als:/,
                'SC-2: success page omits "Verbunden als:" when displayName is empty');
        } else {
            fail('SC-2: HTML reference not available for empty displayName test');
            fail('SC-2: HTML reference not available for empty displayName omission test');
        }

        # Restore default display name
        $Plugins::SpotOn::API::TokenManager::_display_name = 'Test User';
    }
}

done_testing();

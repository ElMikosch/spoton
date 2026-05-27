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
# LMS Module Stubs required by TokenManager.pm
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
# logger() is exported as a function when modules do 'use Slim::Utils::Log'
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
# Also install logger() into caller namespace via import so bare 'logger(...)' works
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
sub ttl    { $_ttl{$_[1]} }   # extra method for test inspection
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
# New stubs for PKCE TokenManager
# ============================================================

# Stub: Slim::Networking::SimpleAsyncHTTP
# Captures callbacks and request data for test inspection.
# simulate_success() and simulate_error() trigger the callbacks.
# MockHTTP is defined inline (not as a separate file) because it has no pkg path.
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
    # body is the last arg when the count of remaining args is odd
    # (Content-Type => 'value' is 2 args, body is 1 arg at end)
    $last_body = $rest[-1] if @rest % 2 != 0;
    return $self;
}
sub get {
    my ($self, $url, @rest) = @_;
    $last_url = $url;
    return $self;
}
# Helper: simulate a successful HTTP response
sub simulate_success {
    my ($class, $json_str) = @_;
    # MockHTTP defined in this same file so content() method is always available
    my $mock_http = bless { _content => $json_str }, 'Slim::Networking::MockHTTP';
    $last_success_cb->($mock_http) if $last_success_cb;
}
# Helper: simulate an HTTP error
sub simulate_error {
    my ($class, $error_str) = @_;
    $last_error_cb->(undef, $error_str) if $last_error_cb;
}

package Slim::Networking::MockHTTP;
sub content { $_[0]->{_content} }
1;
END

# Stub: Crypt::OpenSSL::Random — deterministic for testing
# Note: function (not method) — Crypt::OpenSSL::Random::random_bytes($n)
write_stub($stub_dir, 'Crypt::OpenSSL::Random', <<'END');
package Crypt::OpenSSL::Random;
sub random_bytes { 'x' x $_[1] }   # deterministic: $_[1] is $n (first arg is n, not class)
1;
END

# Stub: URI — simple mock for URL construction
write_stub($stub_dir, 'URI', <<'END');
package URI;
sub new        { bless { _base => $_[1] }, $_[0] }
sub query_form { my $self = shift; $self->{_qf} = [@_] }
sub as_string  { 'https://accounts.spotify.com/authorize?mocked=1' }
sub query      { 'grant_type=authorization_code&code=testcode&redirect_uri=http%3A%2F%2F127.0.0.1%3A9000%2Fplugins%2FSpotOn%2Fsettings%2Fcallback' }
1;
END

# Stub: Digest::SHA — deterministic for testing
write_stub($stub_dir, 'Digest::SHA', <<'END');
package Digest::SHA;
use parent 'Exporter';
our @EXPORT_OK = qw(sha256);
sub sha256 { 'fakehash_' . $_[0] }
1;
END

# Stub: MIME::Base64 — deterministic for testing
write_stub($stub_dir, 'MIME::Base64', <<'END');
package MIME::Base64;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_base64url);
sub encode_base64url { 'b64url_' . unpack('H*', $_[0]) }
1;
END

# ============================================================
# main:: constants (TRANSCODING, WEBUI, SCANNER, INFOLOG, etc.)
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
# into main:: namespace (e.g., preferences(), logger()).
# Must use require + explicit import() call (not 'use') because @INC
# was modified at runtime — compile-time 'use' would find the system module.
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();

# ============================================================
# Tests: TokenManager.pm (skip if not yet created)
# ============================================================

my $tm_module = "$project_dir/Plugins/SpotOn/API/TokenManager.pm";

SKIP: {
    skip "TokenManager.pm not yet created", 22
        unless -f $tm_module;

    require_ok('Plugins::SpotOn::API::TokenManager')
        or BAIL_OUT("Failed to load TokenManager.pm");

    # Helper: reset prefs and cache state between tests
    sub reset_state {
        Slim::Utils::Cache->new()->clear();
    }

    # --------------------------------------------------------
    # AUTH-01: PKCE generation
    # --------------------------------------------------------

    # AUTH-01: _generatePkce returns defined verifier and challenge
    {
        my ($verifier, $challenge) =
            Plugins::SpotOn::API::TokenManager->_generatePkce();
        ok(defined $verifier,  'AUTH-01: _generatePkce returns defined code_verifier');
        ok(length($verifier) > 0, 'AUTH-01: code_verifier is non-empty');
        ok(defined $challenge, 'AUTH-01: _generatePkce returns defined code_challenge');
        ok(length($challenge) > 0, 'AUTH-01: code_challenge is non-empty');
        isnt($verifier, $challenge, 'AUTH-01: code_verifier and code_challenge differ');
    }

    # AUTH-01: _generateState returns a defined, non-empty string
    {
        my $state = Plugins::SpotOn::API::TokenManager->_generateState();
        ok(defined $state,     'AUTH-01: _generateState returns defined state');
        ok(length($state) > 0, 'AUTH-01: state is non-empty');
    }

    # AUTH-01: startOAuthFlow returns auth URL and state, caches PKCE data
    {
        reset_state();
        # Seed clientId in prefs
        preferences('plugin.spoton')->set('clientId', 'testclientid123');

        my ($authUrl, $state) = Plugins::SpotOn::API::TokenManager->startOAuthFlow('testclientid123');
        ok(defined $authUrl, 'AUTH-01: startOAuthFlow returns defined auth URL');
        ok(defined $state,   'AUTH-01: startOAuthFlow returns defined state');
        ok(length($authUrl) > 0, 'AUTH-01: auth URL is non-empty');
        ok(length($state) > 0,   'AUTH-01: state is non-empty');

        # Verify PKCE data was cached under spoton_pkce_$state
        my $pkce_data = Slim::Utils::Cache->new()->get("spoton_pkce_$state");
        ok(defined $pkce_data, 'AUTH-01: PKCE data cached under spoton_pkce_<state>');
        if (defined $pkce_data) {
            ok(defined $pkce_data->{code_verifier}, 'AUTH-01: cached PKCE has code_verifier');
            ok(defined $pkce_data->{client_id},     'AUTH-01: cached PKCE has client_id');
            ok(defined $pkce_data->{redirect_uri},  'AUTH-01: cached PKCE has redirect_uri');
        } else {
            skip "PKCE data not cached — cannot inspect fields", 3;
        }
    }

    # --------------------------------------------------------
    # AUTH-02: Token caching
    # --------------------------------------------------------

    # AUTH-02: _cacheToken stores access token with correct key and TTL
    {
        reset_state();
        Plugins::SpotOn::API::TokenManager->_cacheToken('testacct', 'tok123', 3600);
        my $cache = Slim::Utils::Cache->new();
        is($cache->get('spoton_token_testacct'), 'tok123',
            'AUTH-02: _cacheToken stores token under spoton_token_<accountId>');
        is($cache->ttl('spoton_token_testacct'), 3300,
            'AUTH-02: _cacheToken TTL is expires_in(3600) - 300 = 3300');
    }

    # AUTH-02: _cacheToken with expiresIn between 60 and 300 uses expiresIn directly
    {
        reset_state();
        Plugins::SpotOn::API::TokenManager->_cacheToken('shortacct', 'tok456', 200);
        my $ttl = Slim::Utils::Cache->new()->ttl('spoton_token_shortacct');
        is($ttl, 200, 'AUTH-02: _cacheToken uses expiresIn(200) as TTL when expiresIn < TOKEN_EXPIRY_BUFFER');
    }

    # AUTH-02: refreshToken async flow — success path
    {
        reset_state();
        # Seed account with refresh token in prefs
        preferences('plugin.spoton')->set('accounts', {
            'testacct99' => { refreshToken => 'refresh_tok_xyz', displayName => 'Test User' }
        });
        preferences('plugin.spoton')->set('clientId', 'myclientid');

        my $got_token;
        Plugins::SpotOn::API::TokenManager->refreshToken('testacct99', sub {
            $got_token = shift;
        });

        # Simulate Spotify returning a new access token
        Slim::Networking::SimpleAsyncHTTP->simulate_success(
            '{"access_token":"newtoken_abc","expires_in":3600}'
        );

        is($got_token, 'newtoken_abc',
            'AUTH-02: refreshToken callback receives new access_token');
        is(Slim::Utils::Cache->new()->get('spoton_token_testacct99'), 'newtoken_abc',
            'AUTH-02: refreshToken caches new access_token');
    }

    # AUTH-02: refreshToken updates refresh_token if Spotify returns a new one (Pitfall 7)
    {
        reset_state();
        preferences('plugin.spoton')->set('accounts', {
            'rotateacct' => { refreshToken => 'old_refresh_tok', displayName => 'Rotate User' }
        });
        preferences('plugin.spoton')->set('clientId', 'myclientid');

        Plugins::SpotOn::API::TokenManager->refreshToken('rotateacct', sub { });

        # Simulate Spotify returning both new access and refresh tokens
        Slim::Networking::SimpleAsyncHTTP->simulate_success(
            '{"access_token":"tok_new","refresh_token":"new_refresh_tok","expires_in":3600}'
        );

        my $accts = preferences('plugin.spoton')->get('accounts') || {};
        is($accts->{rotateacct}{refreshToken}, 'new_refresh_tok',
            'AUTH-02: refreshToken stores rotated refresh_token in Prefs');
    }

    # --------------------------------------------------------
    # AUTH-03: refreshAllTokens re-arms timer
    # --------------------------------------------------------
    {
        Slim::Utils::Timers::reset_calls();
        Plugins::SpotOn::API::TokenManager->refreshAllTokens();
        my @sets = @Slim::Utils::Timers::set_calls;
        ok(scalar(@sets) >= 1, 'AUTH-03: refreshAllTokens re-arms timer via setTimer');
    }

    # --------------------------------------------------------
    # AUTH-05: Account management
    # --------------------------------------------------------

    # AUTH-05: getAccountIds returns all account IDs
    {
        preferences('plugin.spoton')->set('accounts', {
            'acct_aaa' => { displayName => 'Alice', refreshToken => 'tok_a' },
            'acct_bbb' => { displayName => 'Bob',   refreshToken => 'tok_b' },
        });
        my @ids = Plugins::SpotOn::API::TokenManager->getAccountIds();
        is(scalar(@ids), 2, 'AUTH-05: getAccountIds returns 2 IDs for 2 seeded accounts');
    }

    # AUTH-05: removeAccount removes from prefs and cache
    {
        reset_state();
        preferences('plugin.spoton')->set('accounts', {
            'remove_me' => { displayName => 'Remove', refreshToken => 'tok_r' },
        });
        Slim::Utils::Cache->new()->set('spoton_token_remove_me', 'cached_tok', 3600);

        Plugins::SpotOn::API::TokenManager->removeAccount('remove_me');

        my %accts = map { $_ => 1 } Plugins::SpotOn::API::TokenManager->getAccountIds();
        ok(!exists $accts{remove_me},
            'AUTH-05: removeAccount removes account from prefs');
        ok(!defined Slim::Utils::Cache->new()->get('spoton_token_remove_me'),
            'AUTH-05: removeAccount clears cached access token');
    }

    # --------------------------------------------------------
    # D-12: getToken cache-first (no async call if cached)
    # --------------------------------------------------------
    {
        reset_state();
        # Seed cache with a token
        Slim::Utils::Cache->new()->set('spoton_token_cached_acct', 'existing_tok', 3300);

        # Reset SimpleAsyncHTTP state to detect if a request was made
        $Slim::Networking::SimpleAsyncHTTP::last_url = undef;

        my $got_token;
        Plugins::SpotOn::API::TokenManager->getToken('cached_acct', sub {
            $got_token = shift;
        });

        is($got_token, 'existing_tok',
            'D-12: getToken returns cached token without making HTTP request');
        ok(!defined $Slim::Networking::SimpleAsyncHTTP::last_url,
            'D-12: getToken does not trigger SimpleAsyncHTTP when token is cached');
    }
}

done_testing();

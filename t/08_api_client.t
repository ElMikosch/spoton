#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Create a temporary directory for LMS stubs
my $stub_dir = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module
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
# LMS Module Stubs
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
# Install logger() into caller namespace so bare 'logger(...)' works
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info     { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn     { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error    { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug    { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# preferences() is exported as a function when modules do 'use Slim::Utils::Prefs'
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

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

# Stub: Slim::Utils::Cache (in-memory, records TTL)
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

# Stub: Slim::Utils::Timers
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_] }
sub killTimers { push @kill_calls, [@_] }
sub reset_calls { @set_calls = (); @kill_calls = () }
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

# Stub: Slim::Utils::Unicode
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

# Stub: JSON::XS::VersionOneAndTwo
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# Stub: Time::HiRes
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: File::Spec::Functions
write_stub($stub_dir, 'File::Spec::Functions', <<'END');
package File::Spec::Functions;
use parent 'Exporter';
use File::Spec ();
our @EXPORT_OK = qw(catdir catfile);
*catdir  = \&File::Spec::catdir;
*catfile = \&File::Spec::catfile;
1;
END

# Stub: Slim::Plugin::OPMLBased
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
# Stub: Slim::Networking::SimpleAsyncHTTP
# Controllable: captures request args, allows manual callback invocation
# ============================================================
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;

our @requests  = ();  # Each entry: { method, url, headers, success_cb, error_cb }
our $auto_mode = 'success';  # 'success', 'error_429', 'error_generic', 'none'
our $last_response_headers = {};

sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless {
        success_cb => $success_cb,
        error_cb   => $error_cb,
        opts       => $opts || {},
    }, $class;
}

sub get  { _dispatch(shift, 'GET',  @_) }
sub post { _dispatch(shift, 'POST', @_) }
sub put  { _dispatch(shift, 'PUT',  @_) }

sub _dispatch {
    my ($self, $method, $url, %headers) = @_;

    my $entry = {
        method     => $method,
        url        => $url,
        headers    => \%headers,
        success_cb => $self->{success_cb},
        error_cb   => $self->{error_cb},
    };
    push @requests, $entry;

    if ($auto_mode eq 'success') {
        my $mock_response = bless {
            _content => '{"display_name":"Test User","id":"spotify_user"}',
            _code    => 200,
        }, 'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($mock_response);
    }
    elsif ($auto_mode eq 'error_429') {
        my $mock_response = bless {
            _code    => 429,
            _headers => $last_response_headers,
        }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '429 Rate limit exceeded', $mock_response);
    }
    elsif ($auto_mode eq 'error_generic') {
        my $mock_response = bless {
            _code    => 500,
            _headers => {},
        }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '500 Internal server error', $mock_response);
    }
    # 'none': no callback, simulates hanging request
}

sub reset_requests { @requests = (); $auto_mode = 'success'; $last_response_headers = {} }

package Slim::Networking::SimpleAsyncHTTP::Response;
sub content  { $_[0]->{_content} }
sub code     { $_[0]->{_code} }
sub response { $_[0] }
sub header   { $_[0]->{_headers}{$_[1]} }

package Slim::Networking::SimpleAsyncHTTP::ErrorResponse;
sub content  { '' }
sub code     { $_[0]->{_code} }
sub response { $_[0] }
sub header   { $_[0]->{_headers}{$_[1]} }

package Slim::Networking::SimpleAsyncHTTP::MockResponse;
sub code     { $_[0]->{_code} }
sub header   { $_[0]->{_headers}{$_[1]} }
sub can      { 1 }
1;
END

# Stub: Plugins::SpotOn::API::TokenManager
# For Client tests: getToken invokes callback immediately with a mock token
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our $mock_token = 'mock_token_abc123';
sub getToken {
    my ($class, $accountId, $flavorOrCb, $cb) = @_;
    if (ref $flavorOrCb eq 'CODE') {
        $cb = $flavorOrCb;
    }
    $cb->($mock_token);
}
sub refreshToken {
    my ($class, $accountId, $flavorOrCb, $cb) = @_;
    if (ref $flavorOrCb eq 'CODE') {
        $cb = $flavorOrCb;
    }
    $cb->($mock_token);
}
1;
END

# ============================================================
# main:: constants
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

# Add paths to @INC
unshift @INC, $stub_dir, $project_dir;

# ============================================================
# Tests: API/Client.pm (skip if not yet created)
# ============================================================

my $client_module = "$project_dir/Plugins/SpotOn/API/Client.pm";

SKIP: {
    skip "Client.pm not yet created (Plan 02-03 will create it)", 10
        unless -f $client_module;

    require_ok('Plugins::SpotOn::API::Client')
        or BAIL_OUT("Failed to load Client.pm");

    # Reset state before tests
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    Slim::Utils::Cache->new()->clear();

    # API-01: getMe routes through _request which uses SimpleAsyncHTTP
    {
        Slim::Networking::SimpleAsyncHTTP::reset_requests();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';

        Plugins::SpotOn::API::Client->getMe('testacct', sub { });

        my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
        ok(scalar(@reqs) > 0, 'API-01: getMe triggers a SimpleAsyncHTTP request');

        my $req = $reqs[0];
        like($req->{url}, qr{api\.spotify\.com/v1/me},
            'API-01: Request URL contains Spotify API /me endpoint');
        like($req->{headers}{'Authorization'}, qr/^Bearer /,
            'API-01: Request includes Authorization: Bearer header');
    }

    # API-02: MAX_CONCURRENT_REQUESTS limits to 3 concurrent dispatches
    {
        Slim::Networking::SimpleAsyncHTTP::reset_requests();
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');

        # Suspend auto-callback to simulate inflight requests
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'none';

        # Fire 5 requests rapidly
        for my $i (1..5) {
            Plugins::SpotOn::API::Client->getMe('testacct', sub { });
        }

        my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
        my $dispatched = scalar(@reqs);
        ok($dispatched <= 3,
            "API-02: MAX_CONCURRENT_REQUESTS=3 respected (dispatched $dispatched of 5 requested)");

        # Reset for subsequent tests
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    }

    # API-03: _cacheTTL returns correct values
    {
        my $ttl_player  = Plugins::SpotOn::API::Client->_cacheTTL('me/player');
        my $ttl_tracks  = Plugins::SpotOn::API::Client->_cacheTTL('me/tracks');
        my $ttl_meta    = Plugins::SpotOn::API::Client->_cacheTTL('tracks/abc123');
        my $ttl_pl      = Plugins::SpotOn::API::Client->_cacheTTL('playlists/abc123');

        is($ttl_player, 0,    'API-03: _cacheTTL returns 0 for me/player (no caching for live state)');
        is($ttl_tracks, 60,   'API-03: _cacheTTL returns 60 for me/tracks (library items)');
        is($ttl_meta,   3600, 'API-03: _cacheTTL returns 3600 for tracks/<id> (metadata)');
        is($ttl_pl,     300,  'API-03: _cacheTTL returns 300 for playlists/<id>');
    }

    # API-04: 429 response sets per-flavor rate-limit key with Retry-After TTL
    {
        Slim::Utils::Cache->new()->clear();
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
        Slim::Networking::SimpleAsyncHTTP::reset_requests();

        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
        $Slim::Networking::SimpleAsyncHTTP::last_response_headers = { 'Retry-After' => 60 };

        my ($result, $err);
        Plugins::SpotOn::API::Client->getMe('testacct', sub {
            ($result, $err) = @_;
        });

        my $cache = Slim::Utils::Cache->new();
        ok($cache->get('spoton_rate_limit_own'), 'API-04: per-flavor rate-limit key set in cache after 429');

        my $ttl = $cache->ttl('spoton_rate_limit_own');
        is($ttl, 60, 'API-04: Rate limit cache TTL equals Retry-After header value');

        # Reset for next test
        $cache->clear();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    }

    # API-04: Retry-After > 300 is capped at 300
    {
        Slim::Utils::Cache->new()->clear();
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
        Slim::Networking::SimpleAsyncHTTP::reset_requests();

        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
        $Slim::Networking::SimpleAsyncHTTP::last_response_headers = { 'Retry-After' => 9999 };

        Plugins::SpotOn::API::Client->getMe('testacct', sub { });

        my $ttl = Slim::Utils::Cache->new()->ttl('spoton_rate_limit_own');
        ok($ttl <= 300,
            "API-04: Retry-After capped at 300s (got $ttl)");

        # Reset
        Slim::Utils::Cache->new()->clear();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    }
}

# API-05: No batch methods exist — verified by source inspection
SKIP: {
    skip "Client.pm not yet created", 1
        unless -f $client_module;

    open(my $fh, '<', $client_module) or BAIL_OUT("Cannot open $client_module: $!");
    my $source = do { local $/; <$fh> };
    close($fh);

    unlike($source, qr/\bgetTracks\b|\bgetAlbums\b|\bgetArtists\b/,
        'API-05: No batch methods (getTracks/getAlbums/getArtists) in Client.pm');
}

# API-06: No LWP or SimpleSyncHTTP in API/ modules — grep test (runs immediately)
{
    my @api_files = glob("$project_dir/Plugins/SpotOn/API/*.pm");

    if (!@api_files) {
        pass('API-06: No API/*.pm files yet — nothing to check for blocking HTTP');
    }
    else {
        for my $f (@api_files) {
            open(my $fh, '<', $f) or die "Cannot open $f: $!";
            my $content = do { local $/; <$fh> };
            close($fh);

            unlike($content, qr/LWP::UserAgent|SimpleSyncHTTP/,
                "API-06: $f contains no blocking HTTP (LWP::UserAgent, SimpleSyncHTTP)");
        }
    }
}

done_testing();

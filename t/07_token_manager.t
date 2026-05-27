#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

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
# Supports preferences('server')->get('cachedir') returning the test cache dir
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

# Stub: Slim::Utils::Unicode
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
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

# No stub needed for File::Spec::Functions — it's a real system module available in Perl core.
# TokenManager.pm uses 'use File::Spec::Functions qw(catdir catfile)' which works with the
# real module. The stub_dir is for LMS-specific modules only.

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
# Mock binary: handles --get-token, --authenticate, --check
# ============================================================
my $mock_bin = "$stub_dir/spoton";
{
    open(my $fh, '>', $mock_bin) or die "Cannot create mock binary: $!";
    print $fh <<'SHELL';
#!/bin/sh
# Mock spoton binary for TokenManager tests
MODE=""
CACHE_DIR=""
i=0
for arg in "$@"; do
    case "$arg" in
        --get-token)    MODE="get-token" ;;
        --authenticate) MODE="authenticate" ;;
        --check)        MODE="check" ;;
        --cache)        NEXT_IS_CACHE=1 ;;
        *)
            if [ "$NEXT_IS_CACHE" = "1" ]; then
                CACHE_DIR="$arg"
                NEXT_IS_CACHE=0
            fi
            ;;
    esac
done

if [ "$MODE" = "get-token" ]; then
    echo '{"accessToken":"mock_token_abc123","expiresIn":3600}'
    exit 0
fi

if [ "$MODE" = "authenticate" ]; then
    if [ -n "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR"
        echo '{"username":"testuser"}' > "$CACHE_DIR/credentials.json"
    fi
    echo "authorized"
    exit 0
fi

if [ "$MODE" = "check" ]; then
    echo "ok spoton v0.8.0-mock"
    echo '{"version":"0.8.0-mock","lms-auth":false,"ogg-direct":false,"passthrough":true}'
    exit 0
fi

exit 1
SHELL
    close($fh);
}
chmod 0755, $mock_bin;

# Stub: Plugins::SpotOn::Helper (returns mock binary path from get())
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<"END");
package Plugins::SpotOn::Helper;
sub get  { '$mock_bin' }
sub init { }
1;
END

# ============================================================
# Add stub_dir and project_dir to @INC
# ============================================================
unshift @INC, $stub_dir, $project_dir;

# ============================================================
# Tests: TokenManager.pm (skip if not yet created)
# ============================================================

my $tm_module = "$project_dir/Plugins/SpotOn/API/TokenManager.pm";

SKIP: {
    skip "TokenManager.pm not yet created (Plans 02-02 will create it)", 12
        unless -f $tm_module;

    require_ok('Plugins::SpotOn::API::TokenManager')
        or BAIL_OUT("Failed to load TokenManager.pm");

    # AUTH-01: refreshToken with mock binary produces a token
    {
        my $got_token;
        Plugins::SpotOn::API::TokenManager->refreshToken('testacct', sub {
            $got_token = shift;
        });
        ok(defined $got_token, 'AUTH-01: refreshToken returns a token');
        is($got_token, 'mock_token_abc123', 'AUTH-01: token value matches mock binary output');
    }

    # AUTH-01: getToken calls refreshToken on cache miss
    {
        # Clear any cached token first
        my $cache = Slim::Utils::Cache->new();
        $cache->remove('spoton_token_gettoken_miss');

        my $got_token;
        Plugins::SpotOn::API::TokenManager->getToken('gettoken_miss', sub {
            $got_token = shift;
        });
        ok(defined $got_token, 'AUTH-01: getToken invokes refreshToken on cache miss and returns token');
    }

    # AUTH-02: Token cached with key "spoton_token_<accountId>"
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->remove('spoton_token_cachetest');

        Plugins::SpotOn::API::TokenManager->refreshToken('cachetest', sub { });

        my $cached = $cache->get('spoton_token_cachetest');
        ok(defined $cached, 'AUTH-02: Token stored in cache under spoton_token_<accountId>');
        is($cached, 'mock_token_abc123', 'AUTH-02: Cached token value is correct');
    }

    # AUTH-02: Token TTL is expiresIn - 300 (mock returns expiresIn=3600, so TTL should be 3300)
    {
        my $cache = Slim::Utils::Cache->new();
        $cache->remove('spoton_token_ttltest');

        Plugins::SpotOn::API::TokenManager->refreshToken('ttltest', sub { });

        my $ttl = $cache->ttl('spoton_token_ttltest');
        is($ttl, 3300, 'AUTH-02: Token TTL is expiresIn(3600) - 300 = 3300');
    }

    # AUTH-03: refreshAllTokens re-arms timer (check Timers stub)
    {
        Slim::Utils::Timers::reset_calls();

        Plugins::SpotOn::API::TokenManager->refreshAllTokens();

        my @sets = @Slim::Utils::Timers::set_calls;
        ok(scalar(@sets) > 0, 'AUTH-03: refreshAllTokens arms a timer via Slim::Utils::Timers::setTimer');
    }

    # AUTH-04: addAccount sets chmod 0700 on dir, 0600 on credentials.json
    {
        my $acct_dir = tempdir(CLEANUP => 1);

        # Temporarily override Helper to point to mock binary
        Plugins::SpotOn::API::TokenManager->addAccount('testuser', 'testpass', sub {
            my ($accountId, $err) = @_;
            ok(!$err, 'AUTH-04: addAccount completes without error');

            if (!$err && $accountId) {
                my $dir  = Plugins::SpotOn::API::TokenManager->_cacheDir($accountId);
                my $cred = "$dir/credentials.json";

                if (-d $dir) {
                    my @stat_dir = stat($dir);
                    is($stat_dir[2] & 07777, 0700,
                        'AUTH-04: Account cache directory has mode 0700');
                }
                if (-f $cred) {
                    my @stat_cred = stat($cred);
                    is($stat_cred[2] & 07777, 0600,
                        'AUTH-04: credentials.json has mode 0600');
                }
            }
        });
    }

    # AUTH-05: Two addAccount calls create separate subdirectories
    {
        Plugins::SpotOn::API::TokenManager->addAccount('user_alpha', 'pass1', sub { });
        Plugins::SpotOn::API::TokenManager->addAccount('user_beta',  'pass2', sub { });

        my @ids = Plugins::SpotOn::API::TokenManager->getAccountIds();
        ok(scalar(@ids) >= 2, 'AUTH-05: getAccountIds returns at least two account IDs after two addAccount calls');

        # Verify they are separate subdirs
        my %dirs_seen;
        for my $id (@ids) {
            my $dir = Plugins::SpotOn::API::TokenManager->_cacheDir($id);
            $dirs_seen{$dir}++;
        }
        my $unique_dirs = grep { $dirs_seen{$_} == 1 } keys %dirs_seen;
        ok($unique_dirs >= 2, 'AUTH-05: Each account has a separate cache subdirectory');
    }

    # AUTH-05: removeAccount removes from prefs and cache
    {
        # Add an account to remove
        my $remove_id;
        Plugins::SpotOn::API::TokenManager->addAccount('user_remove', 'pass3', sub {
            ($remove_id) = @_;
        });

        if ($remove_id) {
            # Seed the token cache
            my $cache = Slim::Utils::Cache->new();
            $cache->set("spoton_token_$remove_id", 'sometoken', 3600);

            Plugins::SpotOn::API::TokenManager->removeAccount($remove_id);

            my @ids_after = Plugins::SpotOn::API::TokenManager->getAccountIds();
            ok(!grep { $_ eq $remove_id } @ids_after,
                'AUTH-05: removeAccount removes account ID from prefs');

            my $cached_after = $cache->get("spoton_token_$remove_id");
            ok(!defined $cached_after,
                'AUTH-05: removeAccount clears cached token from cache');
        } else {
            skip "addAccount did not return an ID — removeAccount tests skipped", 2;
        }
    }
}

done_testing();

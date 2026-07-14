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

# Temporary directory for LMS stubs
my $stub_dir = tempdir(CLEANUP => 1);

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
# LMS Module Stubs (minimal set -- only what Client.pm needs to compile;
# no HTTP dispatch is exercised by this file, only the pure
# _extractPathfinderIds() parser).
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

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

my $prefs_cache_dir = tempdir(CLEANUP => 1);
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

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_] }
sub killTimers { push @kill_calls, [@_] }
sub reset_calls { @set_calls = (); @kill_calls = () }
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

write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: URI::Escape -- not Perl core, bundled by LMS
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape uri_escape_utf8);
sub uri_escape {
    my ($s) = @_;
    die "Can't escape multibyte character" if $s =~ /[^\x00-\xFF]/;
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
sub uri_escape_utf8 {
    my ($s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP -- not exercised by this file
# (only the pure _extractPathfinderIds() parser is tested), but required
# for Client.pm to compile.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new    { bless {}, shift }
sub get    { }
sub post   { }
sub put    { }
sub delete { }
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

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# submodules resolve it via a fully-qualified call at load time.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

# ============================================================
# _subBody($source, $name)
# Extracts the body text of a top-level sub (column-0 `sub NAME {` through
# the line before the next column-0 `sub `) for scoped source assertions --
# mirrors the codebase's grep-style source-inspection tests (t/08 API-05/06).
# ============================================================
sub _subBody {
    my ($source, $name) = @_;
    my @lines = split /\n/, $source;
    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub \Q$name\E\b/) { $start = $i; last; }
    }
    return undef unless defined $start;
    my @body;
    for my $i ($start + 1 .. $#lines) {
        last if $lines[$i] =~ /^sub \w/;
        push @body, $lines[$i];
    }
    return join("\n", @body);
}

# ============================================================
# Tests: Client::_extractPathfinderIds
# ============================================================

my $client_module = "$project_dir/Plugins/SpotOn/API/Client.pm";

SKIP: {
    skip "Client.pm not yet created", 13 unless -f $client_module;

    require_ok('Plugins::SpotOn::API::Client')
        or BAIL_OUT("Failed to load Client.pm");

    skip "_extractPathfinderIds not yet implemented", 12
        unless Plugins::SpotOn::API::Client->can('_extractPathfinderIds');

    # T-52-05-1: valid fixture -> ordered list of 37i9 IDs; non-37i9,
    # non-playlist, missing-uri and malformed entries are filtered out.
    {
        my $fixture = { data => { home => { sectionContainer => { sections => { items => [
            { sectionItems => { items => [
                { uri => 'spotify:playlist:37i9dQZF1E39vTG1lmycOQ' },
                { content => { uri => 'spotify:playlist:37i9dQZF1E37fO0f01qkyz' } },
                { uri => 'spotify:playlist:1abcNotAlgorithmic0000' },   # not 37i9 -> filtered
                { uri => 'spotify:artist:someArtistId0000000000' },    # not a playlist -> filtered
                { uri => undef },                                       # missing uri -> filtered
                { notAUri => 1 },                                       # no uri field at all -> filtered
            ] } },
        ] } } } } };

        my ($ids, $degraded) = Plugins::SpotOn::API::Client->_extractPathfinderIds($fixture);
        is($degraded, 0, 'valid fixture: not flagged as degraded');
        is_deeply($ids, ['37i9dQZF1E39vTG1lmycOQ', '37i9dQZF1E37fO0f01qkyz'],
            'valid fixture: extracts ordered 37i9 playlist IDs, filters non-37i9/non-playlist/malformed entries');
    }

    # Missing data.home -> empty list, does not die.
    {
        my ($ids, $degraded);
        my $lived = eval {
            ($ids, $degraded) = Plugins::SpotOn::API::Client->_extractPathfinderIds({ data => {} });
            1;
        };
        ok($lived, 'missing data.home: extraction does not die');
        is_deeply($ids, [], 'missing data.home: returns empty list');
    }

    # Assorted malformed top-level shapes -> empty list, never dies.
    {
        my $all_lived = 1;
        for my $bad ( {}, { data => undef }, undef, 'not a hashref', [1, 2, 3] ) {
            my ($ids, $degraded);
            my $lived = eval { ($ids, $degraded) = Plugins::SpotOn::API::Client->_extractPathfinderIds($bad); 1 };
            $all_lived &&= $lived;
            is_deeply($ids, [], 'malformed top-level shape returns empty list: '
                . (defined $bad ? (ref($bad) || $bad) : 'undef'));
        }
        ok($all_lived, 'malformed top-level shapes: extraction never dies');
    }

    # Non-array sections.items -> empty list, no die.
    {
        my $fixture = { data => { home => { sectionContainer => { sections => { items => 'not-an-array' } } } } };
        my ($ids, $degraded) = Plugins::SpotOn::API::Client->_extractPathfinderIds($fixture);
        is_deeply($ids, [], 'non-array sections.items: returns empty list');
    }

    # Top-level errors[] (PersistedQueryNotFound-style) -> empty + degrade signal.
    {
        my $fixture = { errors => [ { message => 'PersistedQueryNotFound' } ] };
        my ($ids, $degraded) = Plugins::SpotOn::API::Client->_extractPathfinderIds($fixture);
        is_deeply($ids, [], 'errors[] response: returns empty list');
        ok($degraded, 'errors[] response: degrade signal set (Pitfall 4)');
    }

    # ID validation guard: an over-length candidate is rejected; a valid one
    # is kept and matches the strict regex.
    {
        my $overlong = '37i9' . ('x' x 60);
        my $fixture  = { data => { home => { sectionContainer => { sections => { items => [
            { sectionItems => { items => [
                { uri => "spotify:playlist:$overlong" },
                { uri => 'spotify:playlist:37i9dQZF1E39vTG1lmycOQ' },
            ] } },
        ] } } } } };

        my ($ids, $degraded) = Plugins::SpotOn::API::Client->_extractPathfinderIds($fixture);
        is(scalar(@$ids), 1, 'over-length 37i9 ID rejected by the length guard, valid one kept');
        like($ids->[0], qr/^[A-Za-z0-9]{1,40}$/, 'extracted ID matches the strict validation regex');
    }
}

# ============================================================
# Source assertions (grep-style, mirrors t/08 API-05/API-06 convention)
# ============================================================
SKIP: {
    skip "Client.pm not yet created", 6 unless -f $client_module;

    open(my $fh, '<', $client_module) or BAIL_OUT("Cannot open $client_module: $!");
    my $source = do { local $/; <$fh> };
    close($fh);

    like($source, qr/^sub pathfinderHome\b/m, 'source: Client.pm defines pathfinderHome');
    like($source, qr/^sub getWebPlayerPlaylistItems\b/m, 'source: Client.pm defines getWebPlayerPlaylistItems');
    like($source, qr/\^\[A-Za-z0-9\]\{1,40\}\$/, 'source: strict 37i9 ID validation regex guard present');

    my $body = _subBody($source, 'pathfinderHome');
    if (defined $body) {
        like($body, qr/WebPlayer->getToken/, 'source: pathfinderHome calls WebPlayer->getToken');
        unlike($body, qr/TokenManager->getToken/, 'source: pathfinderHome never calls TokenManager->getToken');
        like($body, qr/WP_RATE_LIMIT_KEY|spoton_wp_rate_limit/,
            'source: pathfinderHome uses the isolated Web-Player rate-limit key, not spoton_rate_limit');
    } else {
        fail('source: could not isolate pathfinderHome sub body for scoped assertions (3 checks)') for 1 .. 3;
    }
}

done_testing();

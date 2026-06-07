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
my $stub_dir  = tempdir(CLEANUP => 1);
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
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless { _calls => [] }, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs (with client() support for per-player prefs)
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
use parent 'Exporter';
our \@EXPORT_OK = qw(preferences);
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
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
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache
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
sub setTimer   { }
sub killTimers { }
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

# Stub: Slim::Player::TranscodingHelper
write_stub($stub_dir, 'Slim::Player::TranscodingHelper', <<'END');
package Slim::Player::TranscodingHelper;
our %commandTable;
sub getConvertCommand2 { return ('command', 'type', 'F', 'T', 0, 1) }
sub Conversions { return \%commandTable }
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

# Stub: Plugins::SpotOn::Helper with controllable getCapability
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $helperCapabilities = {};
sub get { return '/usr/bin/false' }
sub init { }
sub getCapability {
    my ($class, $key) = @_;
    return $helperCapabilities->{$key} if $helperCapabilities && defined $helperCapabilities->{$key};
    return undef;
}
1;
END

# Stub: URI::Escape — not Perl core, bundled by LMS
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape);
sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge; return $s; }
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
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load the Helper stub so _typeString's require finds the stub, not the real module.
# The stub uses a package variable ($helperCapabilities) that tests can control.
require Plugins::SpotOn::Helper;

# ============================================================
# Load Plugin.pm
# ============================================================
require_ok('Plugins::SpotOn::Plugin') or BAIL_OUT("Failed to load Plugin.pm");

# ============================================================
# Mock client object
# ============================================================
# A blessed hashref that the Prefs stub can stringify for client() namespace.
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    sub can { return $_[1] eq 'master' ? 0 : 0 }
}

# ============================================================
# Helper to set prefs for a test case
# ============================================================
sub setup_prefs {
    my (%opts) = @_;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    # Global prefs
    $prefs->set('bitrate', $opts{bitrate}) if exists $opts{bitrate};

    # Per-player prefs (if client provided)
    if ($opts{client}) {
        my $cp = $prefs->client($opts{client});
        $cp->set('bitrateOverride', $opts{bitrateOverride}) if exists $opts{bitrateOverride};
        $cp->set('streamFormat', $opts{streamFormat}) if exists $opts{streamFormat};
        $cp->set('connectOggOverride', $opts{connectOggOverride}) if exists $opts{connectOggOverride};
    }

    # Helper passthrough capability
    if (exists $opts{passthrough}) {
        $Plugins::SpotOn::Helper::helperCapabilities = { passthrough => $opts{passthrough} };
    }
}

# ============================================================
# Test 1: _typeString returns format + mode only (LMS shows bitrate separately)
# ============================================================
{
    my $client = MockClient->new('player_ogg');
    setup_prefs(
        bitrate      => 320,
        client       => $client,
        streamFormat => 'ogg',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'OGG (Spotify Browse)',
        'META-02: streamFormat=ogg, mode=Browse => "OGG (Spotify Browse)"');
}

# ============================================================
# Test 2: _typeString with streamFormat=flac, mode=Connect
# ============================================================
{
    my $client = MockClient->new('player_flac');
    setup_prefs(
        client       => $client,
        streamFormat => 'flac',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Connect');
    is($result, 'FLAC (Spotify Connect)',
        'META-02: streamFormat=flac, mode=Connect => "FLAC (Spotify Connect)"');
}

# ============================================================
# Test 3: _typeString with streamFormat=mp3
# ============================================================
{
    my $client = MockClient->new('player_mp3');
    setup_prefs(
        client       => $client,
        streamFormat => 'mp3',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'MP3 (Spotify Browse)',
        'META-02: streamFormat=mp3 => "MP3 (Spotify Browse)"');
}

# ============================================================
# Test 4: _typeString with streamFormat=pcm
# ============================================================
{
    my $client = MockClient->new('player_pcm');
    setup_prefs(
        client       => $client,
        streamFormat => 'pcm',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM (Spotify Browse)',
        'META-02: streamFormat=pcm => "PCM (Spotify Browse)"');
}

# ============================================================
# Test 5: _typeString with streamFormat=auto + passthrough=1
# D-05: auto resolves to OGG when passthrough capability is true
# ============================================================
{
    my $client = MockClient->new('player_auto_pt');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 1,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'OGG (Spotify Browse)',
        'D-05: streamFormat=auto + passthrough=1 => "OGG (Spotify Browse)"');
}

# ============================================================
# Test 6: _typeString with streamFormat=auto + passthrough=0
# D-05: auto resolves to PCM when passthrough capability is false
# ============================================================
{
    my $client = MockClient->new('player_auto_nopt');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 0,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM (Spotify Browse)',
        'D-05: streamFormat=auto + passthrough=0 => "PCM (Spotify Browse)"');
}

# ============================================================
# Test 7: _typeString with undef client (global prefs only, no crash)
# ============================================================
{
    setup_prefs(
        passthrough => 1,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString(undef, 'Browse');
    is($result, 'OGG (Spotify Browse)',
        'META-03: undef client, auto+passthrough=1 => "OGG (Spotify Browse)"');
}

# ============================================================
# Test 8: _bitrateForClient — bitrateOverride 160 overrides global 320
# D-07: per-player bitrateOverride takes precedence
# ============================================================
{
    my $client = MockClient->new('player_override');
    setup_prefs(
        bitrate         => 320,
        client          => $client,
        bitrateOverride => 160,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateForClient($client);
    is($result, 160,
        'D-07: bitrateOverride=160 overrides global 320');
}

# ============================================================
# Test 9: _bitrateForClient — defaults to global bitrate
# ============================================================
{
    my $client = MockClient->new('player_global');
    setup_prefs(
        bitrate         => 320,
        client          => $client,
        bitrateOverride => undef,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateForClient($client);
    is($result, 320,
        'D-07: no override => global bitrate 320');
}

# ============================================================
# Test 10: _bitrateForClient — undef client uses global
# ============================================================
{
    setup_prefs(
        bitrate => 96,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateForClient(undef);
    is($result, 96,
        'D-07: undef client => global bitrate 96');
}

# ============================================================
# Test 11: D-02 -- mode label always present (Browse)
# ============================================================
{
    my $client = MockClient->new('player_mode_browse');
    setup_prefs(
        bitrate      => 320,
        client       => $client,
        streamFormat => 'ogg',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    like($result, qr/\(Spotify Browse\)$/,
        'D-02: mode label "(Spotify Browse)" always present at end');
}

# ============================================================
# Test 12: D-02 -- mode label always present (Connect)
# ============================================================
{
    my $client = MockClient->new('player_mode_connect');
    setup_prefs(
        bitrate      => 320,
        client       => $client,
        streamFormat => 'ogg',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Connect');
    like($result, qr/\(Spotify Connect\)$/,
        'D-02: mode label "(Spotify Connect)" always present at end');
}

# ============================================================
# Grep Gate: no remaining literal "type => 'Spotify'" in Plugin.pm
# (excluding test files and comments)
# ============================================================
{
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";
    open(my $fh, '<', $plugin_file) or die "Cannot read Plugin.pm: $!";
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comments
        push @matches, $. if $line =~ /type\s*=>\s*'Spotify'/;
    }
    close($fh);
    is(scalar @matches, 0,
        "Grep gate: no remaining literal \"type => 'Spotify'\" in Plugin.pm (found at lines: "
        . join(', ', @matches) . ')');
}

# ============================================================
# Grep Gate: no remaining literal "type => 'Spotify'" in DontStopTheMusic.pm
# (excluding comments)
# ============================================================
{
    my $dstm_file = "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm";
    open(my $fh, '<', $dstm_file) or die "Cannot read DontStopTheMusic.pm: $!";
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comments
        push @matches, $. if $line =~ /type\s*=>\s*'Spotify'/;
    }
    close($fh);
    is(scalar @matches, 0,
        "Grep gate: no remaining literal \"type => 'Spotify'\" in DontStopTheMusic.pm (found at lines: "
        . join(', ', @matches) . ')');
}

# ============================================================
# Grep Gate: no remaining literal "Ogg Vorbis (Spotify)" in Connect.pm
# (excluding comments)
# ============================================================
{
    my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";
    open(my $fh, '<', $connect_file) or die "Cannot read Connect.pm: $!";
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comments
        push @matches, $. if $line =~ /Ogg Vorbis \(Spotify\)/;
    }
    close($fh);
    is(scalar @matches, 0,
        "Grep gate: no remaining literal \"Ogg Vorbis (Spotify)\" in Connect.pm (found at lines: "
        . join(', ', @matches) . ')');
}

done_testing();

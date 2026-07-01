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

# Stub: Slim::Utils::Log (exports logger() for all consumers)
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use Exporter 'import';
our @EXPORT = qw(logger logWarning logError logBacktrace);
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless { _calls => [] }, 'Slim::Utils::Log' }
sub logWarning { }
sub logError   { }
sub logBacktrace { }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 0 }
sub is_debug { 0 }
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

# Stub: JSON::XS (Plugin.pm uses 'use JSON::XS qw(encode_json)')
# JSON::XS is an XS module bundled by LMS but not available in the test env.
# Delegate to JSON::PP (pure-Perl equivalent) so stubs stay test-env clean.
write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
use JSON::PP ();
sub encode_json { JSON::PP::encode_json($_[0]) }
sub decode_json { JSON::PP::decode_json($_[0]) }
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

# Stub: Slim::Utils::Accessor — hash-based replacement for LMS array-based accessor
# Needed when Daemon.pm is loaded via DaemonManager.pm cascade
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { return bless {}, ref($_[0]) || $_[0] }
sub mk_accessor {
    my $class = shift;
    my $type  = shift;
    for my $attr (@_) {
        no strict 'refs';
        *{"${class}::${attr}"} = sub {
            $_[0]->{$attr} = $_[1] if @_ > 1;
            return $_[0]->{$attr};
        };
    }
}
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP — DaemonManager.pm uses at module level
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

# Stub: Slim::Player::Sync — resolver uses slaves() for D-08 sync-group aggregation
write_stub($stub_dir, 'Slim::Player::Sync', <<'END');
package Slim::Player::Sync;
our %_slaves;
sub slaves {
    my $master = shift;
    my $id = "$master";
    return @{ $_slaves{$id} // [] };
}
sub isSlave  { 0 }
sub syncname { ref $_[0] ? "$_[0]" : ($_[0] // '') }
1;
END

# Stub: Slim::Utils::Network — Daemon.pm start() references serverAddr
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

# Stub: Slim::Player::Client — DaemonManager runtime calls (not needed for resolver)
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { undef }
sub clients   { () }
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

# Pre-load Slim::Player::Sync stub so the resolver's sync-group iteration works.
# The stub provides a controllable slaves() function for D-08 sync-group tests.
require Slim::Player::Sync;

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
    use overload '""' => sub { ${$_[0]} }, fallback => 1;
    our %_model;    # id => model string, default 'squeezelite'
    our %_formats;  # id => arrayref, default ['ogg','pcm','flac','mp3']
    our %_synced;   # id => boolean
    our %_master;   # id => MockClient instance or undef
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    sub can {
        my ($self, $method) = @_;
        return 1 if $method eq 'master' && $_master{${$self}};
        return 0;
    }
    sub model   { return $_model{${$_[0]}}   // 'squeezelite' }
    sub formats { return @{ $_formats{${$_[0]}} // ['ogg','pcm','flac','mp3'] } }
    sub isSynced { return $_synced{${$_[0]}} // 0 }
    sub master  { return $_master{${$_[0]}} }
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

        # MockClient per-instance state (keyed by stringified client id)
        my $id = "${$opts{client}}";
        $MockClient::_model{$id}   = $opts{model}   if exists $opts{model};
        $MockClient::_formats{$id} = $opts{formats}  if exists $opts{formats};
        $MockClient::_synced{$id}  = $opts{synced}   if exists $opts{synced};
        $MockClient::_master{$id}  = $opts{master_client} if exists $opts{master_client};

        # Slim::Player::Sync slave list for sync-group tests (D-08)
        if (exists $opts{sync_slaves}) {
            $Slim::Player::Sync::_slaves{$id} = $opts{sync_slaves};
        }
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
    is($result, 'PCM, SpotOn Browse',
        'META-02: streamFormat=ogg currently returns PCM (OGG passthrough not yet wired, #96)');
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
    is($result, 'PCM, SpotOn Connect',
        'META-02: streamFormat=flac currently returns PCM (transcoding not yet wired, #96)');
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
    is($result, 'PCM, SpotOn Browse',
        'META-02: streamFormat=mp3 currently returns PCM (transcoding not yet wired, #96)');
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
    is($result, 'PCM, SpotOn Browse',
        'META-02: streamFormat=pcm => "PCM, SpotOn Browse"');
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
    is($result, 'PCM, SpotOn Browse',
        'D-05: streamFormat=auto + passthrough=1 currently returns PCM (OGG passthrough not yet wired, #96)');
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
    is($result, 'PCM, SpotOn Browse',
        'D-05: streamFormat=auto + passthrough=0 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6a: Hardware model + auto + passthrough=1 => PCM
# D-04: hardware models excluded from passthrough whitelist
# ============================================================
{
    my $client = MockClient->new('player_hw_auto');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 1,
        model        => 'squeezebox2',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04/OGG-02: hardware model squeezebox2 + auto + passthrough=1 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6b: squeezelite + auto + passthrough=0 (binary lacks capability)
# ============================================================
{
    my $client = MockClient->new('player_sl_nopt');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 0,
        model        => 'squeezelite',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: squeezelite + auto + passthrough=0 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6c: squeezelite + auto + passthrough=1 but formats excludes ogg
# Simulates squeezelite started with -e ogg
# ============================================================
{
    my $client = MockClient->new('player_sl_noogg');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 1,
        model        => 'squeezelite',
        formats      => ['pcm', 'flac', 'mp3'],
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: squeezelite without ogg in formats + auto + passthrough=1 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6d: Sync-group mixed capability => PCM for entire group
# D-08: PCM fallback when any sync member cannot decode OGG
# ============================================================
{
    my $master_client = MockClient->new('player_sync_master');
    my $slave_client  = MockClient->new('player_sync_slave');

    # Master: squeezelite with OGG capability
    setup_prefs(
        client       => $master_client,
        streamFormat => 'auto',
        passthrough  => 1,
        model        => 'squeezelite',
        synced       => 1,
        master_client => $master_client,  # master points to itself
        sync_slaves  => [$slave_client],  # Slim::Player::Sync::slaves() returns this
    );
    # Slave: hardware model (not OGG-capable)
    setup_prefs(
        client       => $slave_client,
        streamFormat => 'auto',
        model        => 'squeezebox2',
        synced       => 1,
        master_client => $master_client,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($master_client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-08: sync-group with mixed capability (squeezelite master + squeezebox2 slave) => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 7: _typeString with undef client (global prefs only, no crash)
# D-04: undef client = unknown player = PCM (conservative default)
# ============================================================
{
    setup_prefs(
        passthrough => 1,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString(undef, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: undef client => PCM (unknown player, conservative default)');
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
    like($result, qr/SpotOn Browse$/,
        'D-02: mode label "SpotOn Browse" always present at end');
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
    like($result, qr/SpotOn Connect$/,
        'D-02: mode label "SpotOn Connect" always present at end');
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

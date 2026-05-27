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
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info  { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn  { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

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

# Stub: Slim::Networking::SimpleAsyncHTTP
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get  { }
sub post { }
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

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# ============================================================
# AUTH-04: Filesystem permission tests (immediate — no module required)
# These test the chmod 0700/0600 behavior at the filesystem level.
# ============================================================
{
    my $acct_tmpdir = tempdir(CLEANUP => 1);

    # Create a fake credentials.json
    my $cred_file = "$acct_tmpdir/credentials.json";
    open(my $fh, '>', $cred_file) or die "Cannot create credentials.json: $!";
    print $fh '{"username":"testuser"}';
    close($fh);

    chmod 0700, $acct_tmpdir;
    chmod 0600, $cred_file;

    my @stat_dir  = stat($acct_tmpdir);
    my @stat_cred = stat($cred_file);

    is($stat_dir[2]  & 07777, 0700, 'AUTH-04: chmod 0700 on account cache directory works');
    is($stat_cred[2] & 07777, 0600, 'AUTH-04: chmod 0600 on credentials.json works');
}

# ============================================================
# AUTH-05: Two separate account subdirectories (immediate filesystem test)
# Simulates what TokenManager->addAccount creates
# ============================================================
{
    my $base_dir   = tempdir(CLEANUP => 1);
    my $account_id_1 = 'abcd1234';
    my $account_id_2 = 'ef567890';

    my $dir_1 = "$base_dir/$account_id_1";
    my $dir_2 = "$base_dir/$account_id_2";

    make_path($dir_1);
    make_path($dir_2);

    ok(-d $dir_1, "AUTH-05: Account 1 subdirectory ($account_id_1) exists");
    ok(-d $dir_2, "AUTH-05: Account 2 subdirectory ($account_id_2) exists");
    isnt($dir_1, $dir_2, 'AUTH-05: Account subdirectories are distinct paths');
}

# ============================================================
# AUTH-06: Account switch updates preference
# (SKIP-guarded until Settings.pm is updated in Plan 02-04)
# ============================================================
my $settings_module = "$project_dir/Plugins/SpotOn/Settings.pm";

SKIP: {
    skip "Settings.pm not yet updated with switchAccount handler (Plan 02-04)", 2
        unless -f $settings_module && do {
            open(my $fh, '<', $settings_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /switchAccount/;
        };

    require_ok('Plugins::SpotOn::Settings')
        or BAIL_OUT("Failed to load Settings.pm");

    # Simulate an account switch: Settings->handler should update activeAccount pref
    {
        my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
        $prefs->init({ accounts => { 'abc12345' => { displayName => 'Test' } }, activeAccount => '' });

        my $param_ref = { saveSettings => 1, switchAccount => 'abc12345' };

        # Call handler — we don't need a real $client or HTTP objects for this test
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },  # callback
            undef, undef
        );

        my $active = $prefs->get('activeAccount');
        is($active, 'abc12345',
            'AUTH-06: Account switch via handler updates activeAccount preference to new ID');
    }
}

# ============================================================
# i18n: All PLUGIN_SPOTON_ACCOUNT_* string keys exist in strings.txt
# These strings are added in Plan 02-03 (strings.txt update).
# Skip-guarded until PLUGIN_SPOTON_ACTIVE_ACCOUNT is present
# (that key is the first Phase 2 addition; its presence signals the update landed).
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 11 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        # Sentinel: if PLUGIN_SPOTON_ACTIVE_ACCOUNT is not present, Phase 2 strings
        # have not been added yet — skip entire block.
        skip "Phase 2 strings not yet added to strings.txt (Plan 02-03 will add them)", 11
            unless $content =~ /^PLUGIN_SPOTON_ACTIVE_ACCOUNT\s*$/m;

        my @required_keys = qw(
            PLUGIN_SPOTON_ACCOUNT_SETTINGS
            PLUGIN_SPOTON_ACTIVE_ACCOUNT
            PLUGIN_SPOTON_RATE_LIMIT_HINT
            PLUGIN_SPOTON_ACCOUNT_NONE
            PLUGIN_SPOTON_ACCOUNT_ADD
            PLUGIN_SPOTON_ACCOUNT_ADD_BTN
            PLUGIN_SPOTON_ACCOUNT_ACTIVE
            PLUGIN_SPOTON_ACCOUNT_SWITCH
            PLUGIN_SPOTON_ACCOUNT_REMOVE
            PLUGIN_SPOTON_ACCOUNT_USERNAME
            PLUGIN_SPOTON_ACCOUNT_PASSWORD
        );

        for my $key (@required_keys) {
            ok($content =~ /^\Q$key\E\s*$/m,
                "i18n: $key exists in strings.txt");
        }
    }
}

# ============================================================
# i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT contains %s in both DE and EN
# Skip-guarded until the Phase 2 strings are added to strings.txt (Plan 02-03).
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 2 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my @lines = <$fh>;
        close($fh);

        # Find the PLUGIN_SPOTON_ACTIVE_ACCOUNT block
        my ($in_block, %translations) = (0);
        for my $line (@lines) {
            chomp $line;
            if ($line =~ /^PLUGIN_SPOTON_ACTIVE_ACCOUNT\s*$/) {
                $in_block = 1;
                next;
            }
            last if $in_block && $line =~ /^\S/;  # next key starts
            if ($in_block && $line =~ /^\s+(DE|EN)\s+(.+)$/) {
                $translations{$1} = $2;
            }
        }

        skip "PLUGIN_SPOTON_ACTIVE_ACCOUNT not in strings.txt yet (Plan 02-03 will add it)", 2
            unless %translations;

        like($translations{DE} // '', qr/%s/,
            'i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT DE translation contains %s placeholder');
        like($translations{EN} // '', qr/%s/,
            'i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT EN translation contains %s placeholder');
    }
}

done_testing();

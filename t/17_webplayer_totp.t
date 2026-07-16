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

# Stub: Log::Log4perl::Logger (base class that Slim::Utils::Log inherits)
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

# Stub: Slim::Utils::Log -- installs logger() into caller namespace
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs -- installs preferences() into caller namespace
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

# Stub: Slim::Utils::Cache
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
1;
END

# Stub: Slim::Utils::Timers
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP (not exercised by this file's tests)
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
sub head { }
1;
END

# Stub: JSON::XS::VersionOneAndTwo -- delegates to real JSON::PP
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
    *main::INFOLOG = sub () { 0 };
}

# SPOTON_CACHE_VERSION lives in Plugin.pm (single source of truth);
# WebPlayer.pm resolves it via a fully-qualified call at load time.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::API::WebPlayer')
    or BAIL_OUT('Failed to load WebPlayer.pm');

# ------------------------------------------------------------
# TOTP vector: fixed secret bytes + fixed epoch -> deterministic OTP
# ------------------------------------------------------------
my @secret = (12, 56, 76, 33, 88, 44, 90, 15, 3, 77, 120, 55, 8, 199, 44, 231, 19, 3, 88, 201);
my $epoch  = 1700000000;

my $otp = Plugins::SpotOn::API::WebPlayer::_totp(\@secret, $epoch);

is(length($otp), 6, '_totp returns a 6-character string');
like($otp, qr/^\d{6}$/, '_totp returns a zero-padded 6-digit numeric string');
is($otp, '578737', '_totp produces the expected deterministic OTP for the fixed secret+epoch vector');

my $otp_again = Plugins::SpotOn::API::WebPlayer::_totp(\@secret, $epoch);
is($otp_again, $otp, '_totp is deterministic -- same input always yields the same output');

my $otp_next_window = Plugins::SpotOn::API::WebPlayer::_totp(\@secret, $epoch + 30);
isnt($otp_next_window, $otp, '_totp changes when the 30s time window advances');

# Sanity: WebPlayer.pm must not reach for a base32/OATH module (Pitfall 1)
my $src = do {
    local $/;
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/API/WebPlayer.pm") or die $!;
    <$fh>;
};
unlike($src, qr/Convert::Base32|MIME::Base32|Authen::OATH/,
    'WebPlayer.pm does not reference a base32/OATH CPAN module (Pitfall 1)');
like($src, qr/use Digest::SHA\s+qw\(hmac_sha1\)/,
    'WebPlayer.pm uses Digest::SHA::hmac_sha1 for TOTP');

done_testing();

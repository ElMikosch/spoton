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

# Stub: Slim::Utils::Cache -- exposes remove() so tests can reset state
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP -- captures success/error cb and
# provides simulate_success/simulate_error so getSecret's async path can be
# driven without live HTTP (mirrors t/07_token_manager.t's stub convention).
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our ($last_success_cb, $last_error_cb, $last_url);
sub new {
    my ($class, $success, $error, $opts) = @_;
    $last_success_cb = $success;
    $last_error_cb   = $error;
    return bless {}, $class;
}
sub get {
    my ($self, $url, @rest) = @_;
    $last_url = $url;
    return $self;
}
sub head { return $_[0]; }
sub post { return $_[0]; }
sub simulate_success {
    my ($class, $content) = @_;
    my $mock = bless { _content => $content }, 'Slim::Networking::MockHTTP';
    $last_success_cb->($mock) if $last_success_cb;
}
sub simulate_error {
    my ($class, $error_str) = @_;
    $last_error_cb->(undef, $error_str) if $last_error_cb;
}

package Slim::Networking::MockHTTP;
sub content { $_[0]->{_content} }
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
    *main::INFOLOG = sub () { 0 };
}

BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::API::WebPlayer')
    or BAIL_OUT('Failed to load WebPlayer.pm');

my $SecretSource = 'Plugins::SpotOn::API::WebPlayer::SecretSource';

# ------------------------------------------------------------
# _parseAndValidate: pure validation, no live HTTP
# ------------------------------------------------------------

{
    my $json   = '{"59":[1,2,3],"60":[4,5,6],"61":[7,8,9]}';
    my $result = $SecretSource->_parseAndValidate($json);
    ok($result, '_parseAndValidate accepts well-formed multi-version JSON');
    is($result->{version}, 61, '_parseAndValidate selects the highest numeric version');
    is_deeply($result->{cipher}, [7, 8, 9], '_parseAndValidate returns the cipher array for the selected version');
}

{
    my $json   = '{"61":[1,2,"abc"]}';
    my $result = $SecretSource->_parseAndValidate($json);
    ok(!defined $result, '_parseAndValidate rejects an array containing a non-integer value');
}

{
    my $json   = '{"61":[1,2,300]}';
    my $result = $SecretSource->_parseAndValidate($json);
    ok(!defined $result, '_parseAndValidate rejects an array containing an int > 255');
}

{
    my $json   = '{"61":[1,-5,3]}';
    my $result = $SecretSource->_parseAndValidate($json);
    ok(!defined $result, '_parseAndValidate rejects an array containing a negative int');
}

{
    my $result = $SecretSource->_parseAndValidate('not json at all {{{');
    ok(!defined $result, '_parseAndValidate rejects non-JSON input');
}

{
    my $result = $SecretSource->_parseAndValidate('{}');
    ok(!defined $result, '_parseAndValidate rejects an empty object');
}

# ------------------------------------------------------------
# getSecret: async path via stubbed SimpleAsyncHTTP
# ------------------------------------------------------------

{
    Slim::Utils::Cache->new()->remove('spoton_wp_secret');
    my ($got, $err);
    $SecretSource->getSecret(sub { ($got, $err) = @_; });
    Slim::Networking::SimpleAsyncHTTP->simulate_success('{"59":[1,2,3],"61":[7,8,9]}');
    is($got->{version}, 61, 'getSecret: success path resolves to the highest valid version');
    ok(!defined $err, 'getSecret: success path passes no error reason');
}

{
    Slim::Utils::Cache->new()->remove('spoton_wp_secret');
    my ($got, $err);
    $SecretSource->getSecret(sub { ($got, $err) = @_; });
    Slim::Networking::SimpleAsyncHTTP->simulate_success('{"61":[1,2,999]}');
    ok(!defined $got, 'getSecret: malformed payload (int>255) yields an undef secret');
    is($err, 'unreachable', "getSecret: malformed payload reason is 'unreachable'");
}

{
    Slim::Utils::Cache->new()->remove('spoton_wp_secret');
    my ($got, $err);
    $SecretSource->getSecret(sub { ($got, $err) = @_; });
    Slim::Networking::SimpleAsyncHTTP->simulate_error('timeout');
    ok(!defined $got, 'getSecret: HTTP error yields an undef secret');
    is($err, 'unreachable', "getSecret: HTTP error reason is 'unreachable'");
}

done_testing();

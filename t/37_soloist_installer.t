#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::Installer;
use Plugins::SpotOn::Soloist::Manager;

my $I = 'Plugins::SpotOn::Soloist::Installer';

# ---- Architecture detection and archive URLs. ----
is($I->detect_arch(os => 'linux', archname => 'x86_64-linux-gnu-thread-multi', machine => 'x86_64'),
    'x86_64', 'x86_64 Linux maps to the x86_64 build');
is($I->detect_arch(os => 'linux', archname => 'aarch64-linux-gnu-thread-multi', machine => 'aarch64'),
    'arm64', 'AArch64 Linux maps to the arm64 build');
is($I->detect_arch(os => 'linux', archname => 'arm-linux-gnueabihf-thread-multi-64int', machine => 'armv7l'),
    'arm32', 'ARMv7 hard-float Linux maps to the arm32 build');
is($I->detect_arch(os => 'linux', archname => 'arm-linux-gnueabihf-thread-multi-64int', machine => 'aarch64'),
    'arm32', '32-bit userland on a 64-bit kernel uses the arm32 build');
is($I->detect_arch(os => 'linux', archname => 'arm-linux-gnueabihf-thread-multi-64int', machine => 'armv6l'),
    undef, 'ARMv6 is not supported');
is($I->detect_arch(os => 'linux', archname => 'i686-linux-gnu-thread-multi', machine => 'i686'),
    undef, '32-bit x86 is not supported');
is($I->detect_arch(os => 'darwin', archname => 'darwin-thread-multi-2level', machine => 'arm64'),
    undef, 'macOS is not supported');
is($I->archive_url('arm64'), 'https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz',
    'archive URL uses Spotify\'s stable CDN name');

# ---- Fixtures: release-shaped archives built with the real tar. ----
my $root = tempdir(CLEANUP => 1);
my $fixtures = catdir($root, 'fixtures');
make_path($fixtures);

sub build_archive {
    my ($name, %args) = @_;
    my $dir = catdir($fixtures, "$name-src");
    make_path($dir);
    if ($args{symlink}) {
        symlink('/bin/sh', catfile($dir, 'soloist')) or die "symlink: $!";
    }
    else {
        open(my $fh, '>', catfile($dir, 'soloist')) or die $!;
        print {$fh} "#!/bin/sh\necho '$args{version}'\n";
        # Pad to a plausible executable size.
        print {$fh} '#' x 120, "\n" for 1 .. ($args{small} ? 1 : 9000);
        close($fh);
        chmod 0555, catfile($dir, 'soloist');
    }
    for my $extra (qw(CHANGELOG.md THIRD_PARTY_LICENSES.txt)) {
        open(my $fh, '>', catfile($dir, $extra)) or die $!;
        print {$fh} "$extra\n";
        close($fh);
    }
    my $archive = catfile($fixtures, "$name.tar.gz");
    system('tar', '-czf', $archive, '-C', $dir, 'CHANGELOG.md', 'THIRD_PARTY_LICENSES.txt', 'soloist') == 0
        or die "tar failed";
    return $archive;
}

my $good = build_archive('good', version => 'soloist 1.3.9.38 build 1792476110 (20261020) (g440165f200) (linux/x86_64)');
my $newer = build_archive('newer', version => 'soloist 1.4.0.1 build 1800000000 (20270115) (gabc) (linux/x86_64)');
my $link = build_archive('link', symlink => 1);
my $tiny = build_archive('tiny', version => 'soloist 1.3.9', small => 1);
my $broken = build_archive('broken', version => 'not a soloist');

# ---- Test doubles for LMS HTTP, timers and process spawning. ----
my @timers;
my %served = (archive => $good, etag => '"etag-1"', fail => undef);
my @gets;

{
    package Local::DoneProcess;
    sub new { bless { code => $_[1] }, $_[0] }
    sub alive { 0 }
    sub exit_code { $_[0]{code} }
    sub die { 1 }
}

sub new_installer {
    my (%args) = @_;
    return $I->new(
        base_dir   => $args{base_dir},
        arch       => exists $args{arch} ? $args{arch} : 'x86_64',
        version_of => \&Plugins::SpotOn::Soloist::Manager::_binary_version,
        http_get   => sub {
            my ($url, $file, $ok, $error) = @_;
            push @gets, $url;
            return $error->($served{fail}) if $served{fail};
            copy($served{archive}, $file) or die "copy: $!";
            $ok->({ etag => $served{etag}, last_modified => 'Tue, 20 Oct 2026 06:10:49 GMT' });
        },
        http_head  => sub {
            my ($url, $ok, $error) = @_;
            return $error->($served{fail}) if $served{fail};
            $ok->({ etag => $served{etag} });
        },
        spawn      => sub {
            my ($kind, $spec) = @_;
            my $code = system(@{ $spec->{argv} }) == 0 ? 0 : 2;
            return Local::DoneProcess->new($code);
        },
        timer      => sub { push @timers, $_[1] },
    );
}

sub run_timers {
    while (my $timer = shift @timers) { $timer->() }
}

my $base = catdir($root, 'soloist-managed');
make_path($base, { mode => 0700 });
my $installer = new_installer(base_dir => $base);

ok(!$installer->installed_binary, 'nothing is installed initially');

my @done;
ok(($installer->install(on_done => sub { push @done, [@_] }))[0], 'installation starts');
is($gets[-1], 'https://soloist-builds.spotifycdn.com/soloist_release_x86_64.tar.gz',
    'the build for this architecture is downloaded');
is($installer->status->{state}, 'extracting', 'archive is unpacked asynchronously');
is_deeply([$installer->install()], [0, 'busy'], 'a second installation is refused while busy');
run_timers();

is($installer->status->{state}, 'installed', 'installation completes');
my $binary = catfile($base, 'bin', 'soloist');
is($installer->installed_binary, $binary, 'binary is installed in the private bin directory');
is((stat($binary))[2] & 07777, 0700, 'installed binary is owner-only executable');
is((stat(catdir($base, 'bin')))[2] & 07777, 0700, 'bin directory is private');
ok(!-e catdir($base, 'download'), 'download and extraction files are removed');
ok(!-e catfile($base, 'bin', 'CHANGELOG.md'), 'only the executable is installed');
is($done[-1][0], 1, 'completion callback reports success');
is($done[-1][1]{version}, 'soloist 1.3.9.38', 'completion reports the installed version');
is($installer->status->{version}, 'soloist 1.3.9.38', 'status reports the installed version');
my $info = $installer->installed_info;
is($info->{etag}, '"etag-1"', 'CDN validator is remembered for update checks');
is($info->{buildDate}, '2026-10-20', 'build date is remembered');

# ---- Update checks compare the CDN validator. ----
my @checks;
$installer->check_for_update(sub { push @checks, [@_] });
is($checks[-1][0], 0, 'same ETag means no update');
$served{etag} = '"etag-2"';
$installer->check_for_update(sub { push @checks, [@_] });
is($checks[-1][0], 1, 'changed ETag means an update is available');
$served{fail} = 'connect timeout';
$installer->check_for_update(sub { push @checks, [@_] });
is_deeply($checks[-1], [undef, 'connect timeout'], 'failed checks report the error');
$served{fail} = undef;

# ---- A newer build replaces the old one. ----
$served{archive} = $newer;
ok(($installer->install(on_done => sub { push @done, [@_] }))[0], 'update starts');
run_timers();
is($installer->status->{version}, 'soloist 1.4.0.1', 'newer build is installed');
is($installer->installed_info->{etag}, '"etag-2"', 'new validator is stored');

# ---- Rejected archives leave the installed build untouched. ----
for my $case (
    [$link,   'binary_invalid',      'symlinked executable'],
    [$tiny,   'binary_invalid',      'implausibly small executable'],
    [$broken, 'binary_not_runnable', 'executable without a Soloist version'],
) {
    my ($archive, $code, $label) = @$case;
    $served{archive} = $archive;
    $installer->install(on_done => sub { push @done, [@_] });
    run_timers();
    is($installer->status->{state}, 'failed', "$label is rejected");
    is($installer->status->{error}, $code, "$label reports $code");
    is($done[-1][0], 0, "$label reports failure to the caller");
    is($installer->status->{version}, 'soloist 1.4.0.1', "$label keeps the installed build");
    ok(!-e catdir($base, 'download'), "$label leaves no temporary files");
}

$served{archive} = $good;
$served{fail} = '404 Not Found';
$installer->install(on_done => sub { push @done, [@_] });
is($installer->status->{error}, 'download_failed', 'HTTP errors are reported');
like($installer->status->{message}, qr/404/, 'HTTP error text is kept');
$served{fail} = undef;

# ---- Unsupported hosts never download anything. ----
my $count = @gets;
my $unsupported = new_installer(base_dir => catdir($root, 'other'), arch => undef);
is_deeply([$unsupported->install()], [0, 'unsupported_arch'], 'unsupported architecture is refused');
is(scalar @gets, $count, 'nothing is downloaded on unsupported hosts');
ok(!$unsupported->status->{supported}, 'status reports unsupported architecture');

# ---- A symlinked bin directory is refused. ----
my $evil_base = catdir($root, 'evil');
make_path($evil_base, { mode => 0700 });
make_path(catdir($root, 'elsewhere'));
symlink(catdir($root, 'elsewhere'), catdir($evil_base, 'bin')) or die $!;
my $evil = new_installer(base_dir => $evil_base);
my @evil = $evil->install();
is_deeply([@evil[0, 1]], [0, 'prepare_failed'], 'symlinked bin directory is refused');
ok(!-e catfile($root, 'elsewhere', 'soloist'), 'nothing is written through the symlink');

done_testing();

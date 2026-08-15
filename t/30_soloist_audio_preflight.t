#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::AudioPreflight;

sub make_tools {
    my ($directory, @names) = @_;
    make_path($directory) unless -d $directory;
    for my $name (@names) {
        my $path = catfile($directory, $name);
        open(my $fh, '>', $path) or die "Unable to create $path: $!";
        print {$fh} "#!/bin/sh\nexit 0\n";
        close($fh);
        chmod(0755, $path) or die "Unable to chmod $path: $!";
    }
}

my $root = tempdir(CLEANUP => 1);
my $pulse_bin = catdir($root, 'pulse-bin');
make_tools($pulse_bin, qw(soloist pactl parec ffmpeg));

my $pulse = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
    os                  => 'linux',
    path                => [$pulse_bin],
    websocket_available => 1,
);

ok($pulse->{supportedOs}, 'Linux is supported');
ok($pulse->{capture}{pulseReady}, 'Pulse monitor toolchain is detected');
ok(!$pulse->{capture}{pipewireReady}, 'incomplete native PipeWire toolchain is not ready');
is($pulse->{capture}{preferredBackend}, 'pulse_monitor', 'Pulse monitor is preferred when complete');
is($pulse->{encoder}{preferred}, 'ffmpeg', 'ffmpeg is the preferred encoder');
ok($pulse->{controlReady}, 'Soloist plus LMS WebSocket support makes control ready');
ok($pulse->{audioCaptureReady}, 'capture and encoding toolchain is ready');
ok($pulse->{hardwareProbeReady}, 'complete toolchain is ready for the explicit hardware probe');
is_deeply($pulse->{missing}, [], 'complete toolchain has no missing capability codes');
like($pulse->{tools}{soloist}, qr{\Q$pulse_bin\E}, 'resolved executable path is reported');

my $pipewire_bin = catdir($root, 'pipewire-bin');
make_tools($pipewire_bin, qw(soloist pw-record pw-dump flac));

my $pipewire = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
    os                  => 'linux',
    path                => $pipewire_bin,
    websocket_available => 1,
);
ok($pipewire->{capture}{pipewireReady}, 'native PipeWire capture toolchain is detected');
is(
    $pipewire->{capture}{preferredBackend},
    'pipewire_native',
    'native PipeWire capture is used when Pulse tools are absent',
);
is($pipewire->{encoder}{preferred}, 'flac', 'flac is accepted as encoder fallback');
ok($pipewire->{hardwareProbeReady}, 'native PipeWire fallback can reach probe readiness');

my $empty_bin = catdir($root, 'empty-bin');
make_path($empty_bin);
my $missing = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
    os                  => 'linux',
    path                => [$empty_bin],
    websocket_available => 0,
);
ok(!$missing->{controlReady}, 'missing Soloist and WebSocket support blocks control');
ok(!$missing->{audioCaptureReady}, 'missing audio tools blocks capture');
is_deeply(
    $missing->{missing},
    [qw(soloist_binary lms_simplews audio_capture_tools audio_encoder)],
    'missing capabilities use stable diagnostic codes',
);

my $unsupported = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
    os                  => 'darwin',
    path                => [$pulse_bin],
    websocket_available => 1,
);
ok(!$unsupported->{supportedOs}, 'non-Linux platform is rejected');
ok(!$unsupported->{hardwareProbeReady}, 'tool presence cannot override OS support');
is($unsupported->{missing}[0], 'supported_linux', 'OS limitation is reported first');

my $explicit = Plugins::SpotOn::Soloist::AudioPreflight->inspect(
    os                  => 'linux',
    path                => [$empty_bin],
    soloist_binary      => catfile($pulse_bin, 'soloist'),
    websocket_available => 1,
);
like(
    $explicit->{tools}{soloist},
    qr{\Q$pulse_bin\E},
    'validated explicit Soloist path overrides PATH discovery',
);

done_testing();

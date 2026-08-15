#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use Time::HiRes qw(sleep);
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::StreamPipeline;

my $capture_program = q{binmode STDOUT; my $prefix = $ENV{PIPELINE_TEST_PREFIX} || ''; print STDOUT $prefix, "abc123\n";};

my $encoder_program = q{binmode STDIN; binmode STDOUT; while (1) { my $read = sysread(STDIN, my $buffer, 4096); last unless $read; print STDOUT uc($buffer); }};

my $pipeline = Plugins::SpotOn::Soloist::StreamPipeline->new(
    capture_spec => {
        argv => [$^X, '-e', $capture_program],
        env  => { PIPELINE_TEST_PREFIX => 'pulse:' },
    },
    encoder_spec => {
        argv => [$^X, '-e', $encoder_program],
    },
);

is($pipeline->state(), 'stopped', 'pipeline starts stopped');
ok($pipeline->start(), 'pipeline starts both shell-free children');
is($pipeline->state(), 'running', 'pipeline enters running state');
ok($pipeline->output_fh(), 'pipeline exposes encoded output handle');

my $encoded = '';
my $status;
for (1 .. 100) {
    my ($chunk, $read_status) = $pipeline->read_chunk(1024);
    $status = $read_status;
    $encoded .= $chunk if defined $chunk && length $chunk;
    last if $read_status eq 'eof';
    sleep(0.01) if $read_status eq 'would_block';
}

is($status, 'eof', 'pipeline reports encoder EOF');
is($encoded, "PULSE:ABC123\n", 'capture environment and encoder pipe are wired correctly');
is(
    $pipeline->status_snapshot()->{bytesRead},
    length($encoded),
    'pipeline counts delivered bytes',
);
ok($pipeline->stop(), 'finished pipeline stops idempotently');
is($pipeline->state(), 'stopped', 'stop returns pipeline to stopped state');
ok($pipeline->stop(), 'second stop remains safe');

my $long_capture = q{binmode STDOUT; $SIG{TERM} = sub { exit 0 }; while (1) { print STDOUT "audio" x 100; select undef, undef, undef, 0.02; }};

my $long_pipeline = Plugins::SpotOn::Soloist::StreamPipeline->new(
    capture_spec => { argv => [$^X, '-e', $long_capture] },
    encoder_spec => { argv => [$^X, '-e', $encoder_program] },
);
ok($long_pipeline->start(), 'long-running pipeline starts');
my ($maybe_chunk, $initial_status) = $long_pipeline->read_chunk(4096);
ok(
    $initial_status eq 'data' || $initial_status eq 'would_block',
    'nonblocking read never stalls while pipeline warms up',
);
my $long_snapshot = $long_pipeline->status_snapshot();
ok($long_snapshot->{capturePid} > 1, 'capture PID is reported');
ok($long_snapshot->{encoderPid} > 1, 'encoder PID is reported');
ok($long_pipeline->alive(), 'both pipeline children are alive');
ok($long_pipeline->stop(), 'disconnect stops long-running children');

my $direct_capture = q{binmode STDOUT; print STDOUT "raw-pcm";};
my $direct_pipeline = Plugins::SpotOn::Soloist::StreamPipeline->new(
    capture_spec => { argv => [$^X, '-e', $direct_capture] },
);
ok($direct_pipeline->start(), 'capture-only PCM pipeline starts without an encoder');
my $direct_output = '';
for (1 .. 100) {
    my ($chunk, $read_status) = $direct_pipeline->read_chunk(1024);
    $direct_output .= $chunk if defined $chunk && length $chunk;
    last if $read_status eq 'eof';
    sleep(0.01) if $read_status eq 'would_block';
}
is($direct_output, 'raw-pcm', 'capture-only pipeline preserves PCM bytes exactly');
is(
    $direct_pipeline->status_snapshot()->{encoderPid},
    undef,
    'capture-only pipeline has no encoder child',
);
ok($direct_pipeline->stop(), 'capture-only pipeline stops cleanly');

my $bad_spec_error = eval {
    Plugins::SpotOn::Soloist::StreamPipeline->new(
        capture_spec => { argv => [$^X, "bad\nargument"] },
        encoder_spec => { argv => [$^X, '-e', 'exit 0'] },
    );
    '';
} || $@;
like(
    $bad_spec_error,
    qr/capture argv contains invalid data/,
    'control characters in child argv are rejected',
);

my $missing_spec_error = eval {
    Plugins::SpotOn::Soloist::StreamPipeline->new(
        encoder_spec => { argv => [$^X, '-e', 'exit 0'] },
    );
    '';
} || $@;
like($missing_spec_error, qr/capture spec is required/, 'capture spec is mandatory');

done_testing();

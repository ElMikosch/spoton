#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use Time::HiRes qw(sleep);
use FindBin qw($Bin);

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::ProtocolStream;
use Plugins::SpotOn::Soloist::StreamPipeline;

my $capture = q{binmode STDOUT; $SIG{TERM} = sub { exit 0 }; while (1) { syswrite(STDOUT, "pcm-frame"); select undef, undef, undef, 0.01; }};
my $pipeline = Plugins::SpotOn::Soloist::StreamPipeline->new(
    capture_spec => { argv => [$^X, '-e', $capture] },
);

my $stream = Plugins::SpotOn::Soloist::ProtocolStream->from_pipeline(
    pipeline => $pipeline,
    url      => 'spoton://soloist-pcm:0123456789abcdef01234567',
    client   => bless({}, 'Local::Client'),
    song     => bless({}, 'Local::Song'),
);

isa_ok($stream, 'Plugins::SpotOn::Soloist::ProtocolStream');
ok($stream->opened(), 'protocol stream exposes an open LMS-compatible handle');
is($stream->contentType(), 'soc', 'protocol stream advertises the custom SpotOn PCM type');
is($stream->bitrate(), 44_100 * 16 * 2, 'protocol stream reports S16LE stereo bitrate');
is(
    $stream->url(),
    'spoton://soloist-pcm:0123456789abcdef01234567',
    'protocol stream retains the logical playback URL',
);
ok(!defined $pipeline->output_fh(), 'output handle ownership moved out of the pipeline');

my ($bytes, $read);
for (1 .. 100) {
    $read = $stream->sysread($bytes, 4096);
    last if defined $read && $read > 0;
    sleep(0.01);
}
ok(defined $read && $read > 0, 'LMS can read live PCM directly from the capture pipe');
like($bytes, qr/pcm-frame/, 'capture bytes reach the protocol stream unchanged');
ok($pipeline->alive(), 'capture child remains alive while the stream is open');

ok($stream->close(), 'closing the protocol stream closes its pipe');
is($pipeline->state(), 'stopped', 'closing the protocol stream stops the capture child');
ok(!$stream->opened(), 'protocol handle is closed after teardown');
ok($stream->close(), 'a repeated close remains safe');

{
    package Local::FailedPipeline;
    sub start { 0 }
    sub stop { $_[0]{stopped}++; 1 }
    sub take_output_fh { die 'must not be called' }
}

my $failed = bless {}, 'Local::FailedPipeline';
ok(
    !Plugins::SpotOn::Soloist::ProtocolStream->from_pipeline(pipeline => $failed),
    'a rejected capture pipeline does not create a protocol stream',
);
is($failed->{stopped}, 1, 'a rejected capture pipeline is cleaned up');

done_testing();

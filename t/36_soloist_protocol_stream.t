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

# Live edge: a backlog after a read stall and capture during a pause are
# discarded, so latency never grows over a session.
{
    package Local::PipePipeline;
    sub new { bless { fh => $_[1] }, $_[0] }
    sub start { 1 }
    sub stop { $_[0]{stopped}++; 1 }
    sub take_output_fh { delete $_[0]{fh} }

    package Local::PausableClient;
    sub new { bless { paused => 0 }, $_[0] }
    sub master { $_[0] }
    sub isPaused { $_[0]{paused} }
}
{
    use Errno qw(EWOULDBLOCK);
    use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
    pipe(my $reader, my $writer) or die "pipe: $!";
    binmode($_) for $reader, $writer;
    fcntl($reader, F_SETFL, fcntl($reader, F_GETFL, 0) | O_NONBLOCK) or die $!;
    my $client = Local::PausableClient->new();
    my $live = Plugins::SpotOn::Soloist::ProtocolStream->from_pipeline(
        pipeline => Local::PipePipeline->new($reader),
        url      => 'spoton://soloist-pcm:0123456789abcdef01234567',
        client   => $client,
    );
    my $clock = 100;
    no warnings 'redefine';
    local *Time::HiRes::time = sub { $clock };
    my $put = sub { syswrite($writer, $_[0]) == length($_[0]) or die "write: $!" };
    my $buffer;

    $put->('A' x 1000);
    is($live->sysread($buffer, 4096), 1000, 'live capture is read normally');

    $clock += 0.1;
    $put->('B' x 2000);
    is($live->sysread($buffer, 4096), 2000, 'data within the live window is kept');

    $clock += 3;
    $put->('C' x 30_000);
    my $read = $live->sysread($buffer, 65536);
    ok(!defined $read && $! == EWOULDBLOCK, 'a backlog after a read stall is discarded');
    $put->('D' x 500);
    $clock += 0.01;
    is($live->sysread($buffer, 65536), 500, 'reading continues at the live edge');
    is($buffer, 'D' x 500, 'only fresh capture is delivered after the stall');

    $client->{paused} = 1;
    $put->('E' x 800);
    $read = $live->sysread($buffer, 65536);
    ok(!defined $read && $! == EWOULDBLOCK, 'nothing is delivered while the player is paused');
    $client->{paused} = 0;
    $put->('F' x 300);
    is($live->sysread($buffer, 65536), 300, 'capture from the pause is discarded on resume');
    is($buffer, 'F' x 300, 'resumed playback starts with live audio');
    close($writer);
    $live->close();
}

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

package Plugins::SpotOn::Soloist::ProtocolStream;

use strict;
use warnings;

use base qw(IO::Handle);

use Carp qw(croak);
use Errno qw(EWOULDBLOCK);
use Scalar::Util qw(blessed);
use Time::HiRes ();

use constant PCM_BYTES_PER_SECOND => 44_100 * 2 * 2;

# The capture produces live audio in real time.  When LMS has not read for
# longer than this (player paused, buffers full, event loop busy), the queued
# capture is discarded so playback continues at the live edge instead of
# adding the backlog to the latency for the rest of the session.
use constant LIVE_EDGE_LAG    => 0.5;
use constant DRAIN_CHUNK      => 64 * 1024;
use constant MAX_DRAIN_BYTES  => PCM_BYTES_PER_SECOND * 120;

sub from_pipeline {
    my ($class, %args) = @_;

    my $pipeline = $args{pipeline};
    croak 'Soloist protocol stream pipeline is required'
        unless blessed($pipeline)
            && $pipeline->can('start')
            && $pipeline->can('stop')
            && $pipeline->can('take_output_fh');

    my $started = eval { $pipeline->start() ? 1 : 0 };
    unless ($started) {
        eval { $pipeline->stop() };
        return;
    }

    my $fh = eval { $pipeline->take_output_fh() };
    unless ($fh && defined fileno($fh)) {
        eval { $pipeline->stop() };
        return;
    }

    binmode($fh);
    bless $fh, $class;

    ${*$fh}{'_soloist_pipeline'} = $pipeline;
    ${*$fh}{'contentType'} = 'soc';
    ${*$fh}{'url'} = $args{url};
    ${*$fh}{'client'} = $args{client};
    ${*$fh}{'song'} = $args{song};
    ${*$fh}{'bitrate'} = 44_100 * 16 * 2;

    return $fh;
}

# LMS reads proxied streams with $fh->sysread(...).
sub sysread {
    my $self = $_[0];
    my $now = Time::HiRes::time();
    my $live = ${*$self}{'_soloist_live'} ||= { anchor => $now, bytes => 0 };

    # A paused player would buffer the capture (silence while Spotify is
    # paused) and play it back after resuming.  Keep the capture at the live
    # edge instead and hand LMS nothing until playback resumes.
    my $paused = _player_paused(${*$self}{'client'});
    my $lag = ($now - $live->{anchor}) - $live->{bytes} / PCM_BYTES_PER_SECOND;
    if ($paused || $lag > LIVE_EDGE_LAG) {
        $self->_drain();
        $live->{anchor} = $now;
        $live->{bytes} = 0;
        if ($paused) {
            $! = EWOULDBLOCK;
            return undef;
        }
    }

    my $read = CORE::sysread($self, $_[1], $_[2], $_[3] || 0);
    $live->{bytes} += $read if $read;
    return $read;
}

sub _drain {
    my ($self) = @_;
    my $total = 0;
    while ($total < MAX_DRAIN_BYTES) {
        my $read = CORE::sysread($self, my $discard, DRAIN_CHUNK);
        last unless $read;
        $total += $read;
    }
    return $total;
}

sub _player_paused {
    my ($client) = @_;
    return 0 unless blessed($client);
    my $master = $client->can('master') ? eval { $client->master() } : undef;
    $master ||= $client;
    return 0 unless $master->can('isPaused');
    return eval { $master->isPaused() } ? 1 : 0;
}

sub contentType {
    return ${*{ $_[0] }}{'contentType'};
}

sub url {
    return ${*{ $_[0] }}{'url'};
}

sub client {
    return ${*{ $_[0] }}{'client'};
}

sub bitrate {
    return ${*{ $_[0] }}{'bitrate'};
}

sub close {
    my ($self) = @_;

    my $pipeline = delete ${*$self}{'_soloist_pipeline'};
    my $closed = defined fileno($self) ? $self->SUPER::close() : 1;
    eval { $pipeline->stop() } if $pipeline;
    return $closed;
}

sub DESTROY {
    my ($self) = @_;
    $self->close();
}

1;

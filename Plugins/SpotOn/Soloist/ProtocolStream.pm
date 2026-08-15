package Plugins::SpotOn::Soloist::ProtocolStream;

use strict;
use warnings;

use base qw(IO::Handle);

use Carp qw(croak);
use Scalar::Util qw(blessed);

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

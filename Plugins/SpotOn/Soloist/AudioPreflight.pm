package Plugins::SpotOn::Soloist::AudioPreflight;

use strict;
use warnings;

use Config ();
use Cwd qw(abs_path);
use File::Spec;

my @TOOLS = qw(
    soloist
    pulseaudio
    pactl
    parec
    pw-record
    pw-dump
    pw-cli
    ffmpeg
    flac
    sox
);

# Inspect only executable availability.  This is safe to call from the LMS
# event loop: it does not start a process, connect to an audio server, or read
# user-selected paths.  Runtime audio-server checks belong in the later,
# explicit hardware probe.
sub inspect {
    my ($class, %args) = @_;

    my $os = defined $args{os} ? $args{os} : $^O;
    my $supported_os = $os eq 'linux' ? 1 : 0;
    my @path = _path_entries($args{path});

    my %tools;
    for my $name (@TOOLS) {
        my $path = _find_executable($name, \@path);
        my $key = _json_key($name);
        $tools{$key} = $path if defined $path;
    }

    if (defined $args{soloist_binary}) {
        my $candidate = $args{soloist_binary};
        if (!ref($candidate) && -f $candidate && -x $candidate) {
            $tools{soloist} = abs_path($candidate) || $candidate;
        }
    }

    my $pulse_ready = $tools{pactl} && $tools{parec} ? 1 : 0;
    my $managed_pulse_ready = $tools{pulseaudio} && $pulse_ready ? 1 : 0;
    my $pipewire_ready = $tools{pwRecord}
        && ($tools{pwDump} || $tools{pwCli}) ? 1 : 0;

    my ($capture_backend, $capture_binary);
    if ($pulse_ready) {
        $capture_backend = 'pulse_monitor';
        $capture_binary = $tools{parec};
    }
    elsif ($pipewire_ready) {
        $capture_backend = 'pipewire_native';
        $capture_binary = $tools{pwRecord};
    }

    my ($encoder, $encoder_binary);
    for my $candidate (qw(ffmpeg flac sox)) {
        if ($tools{$candidate}) {
            $encoder = $candidate;
            $encoder_binary = $tools{$candidate};
            last;
        }
    }

    my $websocket = $args{websocket_available} ? 1 : 0;
    my $control_ready = $supported_os && $tools{soloist} && $websocket ? 1 : 0;
    my $audio_capture_ready = $supported_os && $capture_backend && $encoder ? 1 : 0;
    my $managed_pulse_audio_ready =
        $supported_os && $managed_pulse_ready && $encoder ? 1 : 0;
    my $hardware_probe_ready = $control_ready && $audio_capture_ready ? 1 : 0;

    my @missing;
    push @missing, 'supported_linux' unless $supported_os;
    push @missing, 'soloist_binary' unless $tools{soloist};
    push @missing, 'lms_simplews' unless $websocket;
    push @missing, 'audio_capture_tools' unless $capture_backend;
    push @missing, 'audio_encoder' unless $encoder;

    return {
        os                   => $os,
        supportedOs          => $supported_os,
        websocketAvailable   => $websocket,
        tools                => \%tools,
        capture              => {
            pulseReady        => $pulse_ready,
            managedPulseReady => $managed_pulse_ready,
            pipewireReady     => $pipewire_ready,
            preferredBackend  => $capture_backend,
            binary            => $capture_binary,
        },
        encoder              => {
            available => $encoder ? 1 : 0,
            preferred => $encoder,
            binary    => $encoder_binary,
        },
        controlReady           => $control_ready,
        audioCaptureReady      => $audio_capture_ready,
        managedPulseAudioReady => $managed_pulse_audio_ready,
        hardwareProbeReady     => $hardware_probe_ready,
        missing                => \@missing,
    };
}

sub _path_entries {
    my ($path) = @_;

    if (ref($path) eq 'ARRAY') {
        return grep { defined $_ && !ref($_) && length($_) } @$path;
    }

    $path = $ENV{PATH} unless defined $path;
    return () if !defined $path || ref($path);

    my $separator = $Config::Config{path_sep} || ':';
    return grep { length($_) } split(/\Q$separator\E/, $path, -1);
}

sub _find_executable {
    my ($name, $path) = @_;

    return undef unless defined $name && $name =~ /\A[A-Za-z0-9_.+-]+\z/;
    for my $directory (@$path) {
        next unless -d $directory;
        my $candidate = File::Spec->catfile($directory, $name);
        next unless -f $candidate && -x $candidate;
        return abs_path($candidate) || $candidate;
    }
    return undef;
}

sub _json_key {
    my ($name) = @_;
    $name =~ s/-([a-z])/uc($1)/eg;
    return $name;
}

1;

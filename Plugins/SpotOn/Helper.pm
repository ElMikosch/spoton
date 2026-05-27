package Plugins::SpotOn::Helper;

use strict;
use warnings;
use Config;
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant HELPER             => 'spoton';
use constant MIN_BINARY_VERSION => '1.0.0';

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

my ($helper, $helperVersion, $helperCapabilities);

sub init {
    # aarch64 kann als Fallback armhf-Binaries verwenden
    if ( !main::ISWINDOWS && !main::ISMAC
         && Slim::Utils::OSDetect::details()->{osArch} =~ /^aarch64/i ) {
        Slim::Utils::Misc::addFindBinPaths(
            catdir(Plugins::SpotOn::Plugin->_pluginDataFor('basedir'), 'Bin', 'armhf-linux')
        );
    }

    $prefs->setChange( sub {
        $helper = $helperVersion = $helperCapabilities = undef;
    }, 'binary') if !main::SCANNER;
}

sub get {
    if ( !$helper && (my $candidate = $prefs->get('binary')) ) {
        my $check;
        helperCheck($candidate, \$check);

        if ($helper) {
            main::INFOLOG && $log->info("Using helper from prefs: $helper");
        } else {
            $log->warn("Pref-path binary check failed: $check") if $check;
        }
    }

    if (!$helper) {
        my $check;
        $helper = _findBin(sub {
            helperCheck(@_, \$check);
        }, 'custom-first');

        if (!$helper) {
            $log->warn("Didn't find SpotOn helper application!");
            $log->warn("Last error: \n" . $check) if $check;
        }
    }

    return wantarray ? ($helper, $helperVersion) : $helper;
}

sub helperCheck {
    my ($candidate, $check, $dontSet) = @_;

    $$check = '' unless $check && ref $check;

    # Shell-safe quoting to prevent command injection from user-supplied binary paths
    (my $safe = $candidate) =~ s/'/'\\''/g;
    my $checkCmd = sprintf("'%s' -n 'SpotOn' --check", $safe);
    $$check = `$checkCmd 2>&1`;

    # KRITISCH: 'spoton' nicht 'spotty' im Regex
    if ( $$check && $$check =~ /^ok spoton v([\d\.]+)/i ) {
        my $version = $1;

        # SpotOn-Erweiterung: Mindestversions-Pruefung
        if ( _versionCompare($version, MIN_BINARY_VERSION) < 0 ) {
            $log->warn("Binary version $version below minimum " . MIN_BINARY_VERSION);
            return 0;
        }

        return 1 if $dontSet;

        $helper        = $candidate;
        $helperVersion = $version;

        if ( $$check =~ /\n(.*)/s ) {
            $helperCapabilities = eval { from_json($1) } || {};
        }

        return 1;
    }
}

sub getCapability {
    my ($class, $key) = @_;
    return $helperCapabilities->{$key} if $helperCapabilities && defined $helperCapabilities->{$key};
    return undef;
}

sub getVersion {
    my ($class) = @_;

    if (!$helperVersion) {
        $class->get();
    }

    return $helperVersion;
}

sub version {
    my $class = shift;
    return $class->getVersion();
}

# Angepasster Binary-Finder um findbin() von LMS zu nutzen
sub _findBin {
    my ($checkerCb, $customFirst) = @_;

    my @candidates = (HELPER);    # 'spoton'
    my $binary;

    if (Slim::Utils::OSDetect::OS() eq 'unix') {
        # auf 64 bit x86 zuerst x86_64-Build versuchen
        if ( $Config::Config{'archname'} =~ /x86_64/ ) {
            push @candidates, HELPER . '-x86_64';
        }
    }

    # Custom-Override zuerst (LMS-10 Vorbereitung)
    unshift @candidates, HELPER . '-custom';

    foreach my $name (@candidates) {
        my $candidate = Slim::Utils::Misc::findbin($name) || next;

        $candidate = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($candidate);

        next unless -f $candidate && -x $candidate;

        main::INFOLOG && $log->is_info && $log->info("Trying helper application: $candidate");

        if ( !$checkerCb || $checkerCb->($candidate) ) {
            main::INFOLOG && $log->is_info && $log->info("Found helper application: $candidate");
            $binary = $candidate;
            last;
        }
    }

    return $binary;
}

sub _versionCompare {
    my ($v1, $v2) = @_;
    my @a = split /\./, $v1;
    my @b = split /\./, $v2;
    for my $i (0 .. $#b) {
        my $diff = ($a[$i] || 0) <=> ($b[$i] || 0);
        return $diff if $diff;
    }
    return 0;
}

1;

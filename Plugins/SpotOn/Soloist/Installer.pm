package Plugins::SpotOn::Soloist::Installer;

use strict;
use warnings;

use Carp qw(croak);
use Config ();
use File::Path qw(make_path remove_tree);
use File::Spec::Functions qw(catdir catfile);
use JSON::PP ();
use POSIX ();
use Time::HiRes ();

# Download the official Soloist build for this host from Spotify's CDN and
# install it into the plugin's private data directory.  The archive is fetched
# by this LMS server itself; SpotOn never redistributes Soloist.
#
# Every LMS-specific operation (HTTP, timers, process spawning, version check)
# is injectable so the state machine can be tested without LMS.

use constant CDN_BASE         => 'https://soloist-builds.spotifycdn.com/';
use constant DOWNLOAD_TIMEOUT => 300;
use constant EXTRACT_TIMEOUT  => 120;
use constant POLL_INTERVAL    => 0.25;
use constant MIN_BINARY_BYTES => 1_000_000;
use constant MAX_BINARY_BYTES => 300_000_000;

my %ARCHIVES = (
    x86_64 => 'soloist_release_x86_64.tar.gz',
    arm64  => 'soloist_release_arm64.tar.gz',
    arm32  => 'soloist_release_arm32.tar.gz',
);

# Soloist publishes Linux builds for x86_64, AArch64 and ARMv7 hard-float.
# Perl's own architecture describes the userland the binary must link
# against; uname distinguishes ARMv6 CPUs from ARMv7 ones.
sub detect_arch {
    my ($class, %args) = @_;
    my $os = defined $args{os} ? $args{os} : $^O;
    return undef unless $os eq 'linux';

    my $archname = defined $args{archname}
        ? $args{archname}
        : ($Config::Config{archname} || '');
    my $machine = defined $args{machine}
        ? $args{machine}
        : ((POSIX::uname())[4] || '');

    return 'x86_64' if $archname =~ /\Ax86_64-linux/;
    return 'arm64'  if $archname =~ /\Aaarch64-linux/;
    return 'arm32'
        if $archname =~ /\Aarm.*-linux.*(?:gnueabihf|armhf)/
            && $machine =~ /\A(?:armv[78]|aarch64|arm64)/;
    return undef;
}

sub archive_url {
    my ($class, $arch) = @_;
    return unless defined $arch && $ARCHIVES{$arch};
    return CDN_BASE . $ARCHIVES{$arch};
}

sub new {
    my ($class, %args) = @_;
    croak 'Soloist installer base_dir is required'
        unless defined $args{base_dir} && length $args{base_dir};
    croak 'Soloist installer version_of is required'
        unless ref($args{version_of}) eq 'CODE';

    return bless {
        base_dir   => $args{base_dir},
        arch       => exists $args{arch} ? $args{arch} : $class->detect_arch(),
        version_of => $args{version_of},
        http_get   => $args{http_get}  || \&_lms_http_get,
        http_head  => $args{http_head} || \&_lms_http_head,
        spawn      => $args{spawn}     || \&_spawn_process,
        timer      => $args{timer}     || \&_set_timer,
        tar_binary => $args{tar_binary},
        clock      => $args{clock}     || sub { Time::HiRes::time() },
        state      => 'idle',
    }, $class;
}

sub arch { $_[0]{arch} }
sub supported { defined $_[0]{arch} ? 1 : 0 }
sub busy { $_[0]{state} eq 'downloading' || $_[0]{state} eq 'extracting' ? 1 : 0 }
sub bin_dir { catdir($_[0]{base_dir}, 'bin') }
sub binary_path { catfile($_[0]->bin_dir, 'soloist') }
sub work_dir { catdir($_[0]{base_dir}, 'download') }

sub installed_binary {
    my ($self) = @_;
    my $path = $self->binary_path;
    return -f $path && !-l $path && -x _ ? $path : undef;
}

sub installed_info {
    my ($self) = @_;
    my $path = catfile($self->bin_dir, 'soloist.json');
    open(my $fh, '<', $path) or return {};
    local $/;
    my $json = <$fh>;
    close($fh);
    my $info = eval { JSON::PP::decode_json($json) };
    return ref($info) eq 'HASH' ? $info : {};
}

sub status {
    my ($self) = @_;
    my $info = $self->installed_info;
    return {
        state       => $self->{state},
        error       => $self->{error},
        message     => $self->{message},
        startedAt   => $self->{started_at},
        finishedAt  => $self->{finished_at},
        arch        => $self->{arch},
        supported   => $self->supported,
        installed   => $self->installed_binary ? 1 : 0,
        version     => $info->{version},
        installedAt => $info->{installedAt},
        lastCheckAt => $self->{last_check_at},
    };
}

# Start an asynchronous download and installation.  on_done receives
# (1, $info) or (0, $error_code, $message) once the process has finished.
sub install {
    my ($self, %args) = @_;
    return (0, 'busy') if $self->busy;
    return (0, 'unsupported_arch') unless $self->supported;

    $self->{on_done}     = $args{on_done};
    $self->{started_at}  = $self->{clock}->();
    $self->{finished_at} = undef;
    $self->{error}       = undef;
    $self->{message}     = undef;
    $self->{state}       = 'downloading';

    my $prepared = eval {
        _secure_directory($self->{base_dir});
        _secure_directory($self->bin_dir);
        remove_tree($self->work_dir) if -e $self->work_dir || -l $self->work_dir;
        _secure_directory($self->work_dir);
        _secure_directory(catdir($self->work_dir, 'extract'));
        1;
    };
    return $self->_fail('prepare_failed', $@) unless $prepared;

    my $archive = catfile($self->work_dir, 'soloist.tar.gz');
    my $url = $self->archive_url($self->{arch});
    my $started = eval {
        $self->{http_get}->(
            $url,
            $archive,
            sub { $self->_downloaded($archive, @_) },
            sub { $self->_fail('download_failed', $_[0]) },
        );
        1;
    };
    return $self->_fail('download_failed', $@) unless $started;
    return (1);
}

# Ask the CDN whether a build other than the installed one is available.
# The callback receives (1|0, $headers) or (undef, $error).
sub check_for_update {
    my ($self, $callback) = @_;
    return $callback->(undef, 'unsupported_arch') unless $self->supported;
    $self->{last_check_at} = $self->{clock}->();
    my $info = $self->installed_info;
    $self->{http_head}->(
        $self->archive_url($self->{arch}),
        sub {
            my ($headers) = @_;
            $headers ||= {};
            my $available = !$self->installed_binary
                || !_same_build($info, $headers);
            $callback->($available ? 1 : 0, $headers);
        },
        sub { $callback->(undef, $_[0]) },
    );
    return 1;
}

sub _downloaded {
    my ($self, $archive, $headers) = @_;
    return unless $self->{state} eq 'downloading';
    $self->{headers} = ref($headers) eq 'HASH' ? $headers : {};
    return $self->_fail('download_failed', 'Downloaded archive is empty')
        unless -s $archive;

    my $tar = $self->{tar_binary} || _find_executable('tar');
    return $self->_fail('tar_missing', 'The tar program was not found')
        unless $tar;

    my $log_path = catfile($self->work_dir, 'extract.log');
    open(my $log_fh, '>', $log_path)
        or return $self->_fail('extract_failed', "Unable to open extract log: $!");
    $self->{log_fh} = $log_fh;
    $self->{log_path} = $log_path;

    # Extract the single executable by name; the archive's licenses and
    # changelog are not needed at runtime.
    my $process = eval {
        $self->{spawn}->(
            'tar',
            {
                argv => [
                    $tar, '-xzf', $archive,
                    '-C', catdir($self->work_dir, 'extract'),
                    'soloist',
                ],
                env => {},
            },
            $log_fh,
            $log_fh,
        );
    };
    return $self->_fail('extract_failed', $@ || 'Unable to start tar')
        unless $process;

    $self->{process}  = $process;
    $self->{deadline} = $self->{clock}->() + EXTRACT_TIMEOUT;
    $self->{state}    = 'extracting';
    $self->{timer}->(POLL_INTERVAL, sub { $self->_poll_extract });
    return 1;
}

sub _poll_extract {
    my ($self) = @_;
    return unless $self->{state} eq 'extracting';
    my $process = $self->{process};

    if (eval { $process->alive }) {
        if ($self->{clock}->() >= $self->{deadline}) {
            eval { $process->die };
            return $self->_fail('extract_timeout', 'Unpacking the Soloist archive timed out');
        }
        $self->{timer}->(POLL_INTERVAL, sub { $self->_poll_extract });
        return;
    }

    my $code = eval { $process->exit_code };
    delete $self->{process};
    return $self->_fail('extract_failed', 'tar exited with code ' . (defined $code ? $code : '?'))
        if !defined $code || $code != 0;
    return $self->_verify_and_install;
}

sub _verify_and_install {
    my ($self) = @_;
    my $candidate = catfile($self->work_dir, 'extract', 'soloist');

    my @stat = lstat($candidate);
    return $self->_fail('binary_missing', 'The archive did not contain soloist')
        unless @stat;
    return $self->_fail('binary_invalid', 'soloist in the archive is not a regular file')
        if -l _ || !-f _;
    # A hard link would let chmod below change some other file.
    return $self->_fail('binary_invalid', 'soloist in the archive is a hard link')
        if $stat[3] != 1;
    return $self->_fail('binary_invalid', 'soloist in the archive has an implausible size')
        if $stat[7] < MIN_BINARY_BYTES || $stat[7] > MAX_BINARY_BYTES;
    chmod(0700, $candidate)
        or return $self->_fail('binary_invalid', "Unable to make soloist executable: $!");

    my %build = eval { $self->{version_of}->($candidate) };
    return $self->_fail(
        'binary_not_runnable',
        'The downloaded soloist does not run on this system',
    ) unless defined $build{version} && $build{version} =~ /\Asoloist\s+\d/;

    rename($candidate, $self->binary_path)
        or return $self->_fail('install_failed', "Unable to install soloist: $!");

    my $info = {
        version      => $build{version},
        buildDate    => $build{build_date},
        expiresAt    => $build{expires_at},
        arch         => $self->{arch},
        etag         => $self->{headers}{etag},
        lastModified => $self->{headers}{last_modified},
        installedAt  => int($self->{clock}->()),
    };
    eval { _write_info(catfile($self->bin_dir, 'soloist.json'), $info) };

    $self->_cleanup;
    $self->{state}   = 'installed';
    $self->{message} = $build{version};
    return $self->_finish(1, $info);
}

sub _fail {
    my ($self, $code, $message) = @_;
    $message = defined $message ? "$message" : '';
    $message =~ s/[\x00-\x1f\x7f]+/ /g;
    $message =~ s/^\s+|\s+$//g;
    if ($self->{process}) {
        eval { $self->{process}->die };
        delete $self->{process};
    }
    $self->_cleanup;
    $self->{state} = 'failed';
    $self->{error} = $code;
    $self->{message} = $message;
    return $self->_finish(0, $code, $message);
}

sub _finish {
    my ($self, $ok, @result) = @_;
    $self->{finished_at} = $self->{clock}->();
    my $callback = delete $self->{on_done};
    eval { $callback->($ok, @result) } if ref($callback) eq 'CODE';
    return ($ok ? 1 : 0, @result);
}

sub _cleanup {
    my ($self) = @_;
    close(delete $self->{log_fh}) if $self->{log_fh};
    remove_tree($self->work_dir) if -d $self->work_dir && !-l $self->work_dir;
}

sub _same_build {
    my ($info, $headers) = @_;
    if (defined $headers->{etag} && defined $info->{etag}) {
        return $headers->{etag} eq $info->{etag};
    }
    if (defined $headers->{last_modified} && defined $info->{lastModified}) {
        return $headers->{last_modified} eq $info->{lastModified};
    }
    # Without a comparable validator, keep the installed build.
    return 1;
}

sub _write_info {
    my ($path, $info) = @_;
    my $tmp = "$path.new";
    open(my $fh, '>', $tmp) or die "Unable to write $tmp: $!";
    print {$fh} JSON::PP->new->canonical->encode($info);
    close($fh) or die "Unable to write $tmp: $!";
    chmod(0600, $tmp);
    rename($tmp, $path) or die "Unable to install $path: $!";
}

sub _secure_directory {
    my ($path) = @_;
    make_path($path, { mode => 0700 }) unless -e $path || -l $path;
    my @stat = lstat($path);
    die "Unable to inspect $path\n" unless @stat;
    die "$path must not be a symlink\n" if -l _;
    die "$path is not a directory\n" unless -d _;
    die "$path has the wrong owner\n" unless $stat[4] == $>;
    chmod(0700, $path) or die "Unable to protect $path: $!\n";
    return 1;
}

sub _find_executable {
    my ($name) = @_;
    for my $directory (split /:/, ($ENV{PATH} || '/usr/bin:/bin')) {
        next unless length $directory;
        my $candidate = catfile($directory, $name);
        return $candidate if -f $candidate && -x _;
    }
    for my $candidate ("/bin/$name", "/usr/bin/$name") {
        return $candidate if -f $candidate && -x _;
    }
    return undef;
}

sub _headers_of {
    my ($http) = @_;
    my $headers = eval { $http->headers } or return {};
    return {
        etag          => scalar eval { $headers->header('ETag') },
        last_modified => scalar eval { $headers->header('Last-Modified') },
    };
}

sub _lms_http_get {
    my ($url, $file, $ok, $error) = @_;
    require Slim::Networking::SimpleAsyncHTTP;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub { $ok->(_headers_of($_[0])) },
        sub { $error->($_[1]) },
        { saveAs => $file, timeout => DOWNLOAD_TIMEOUT },
    )->get($url);
}

sub _lms_http_head {
    my ($url, $ok, $error) = @_;
    require Slim::Networking::SimpleAsyncHTTP;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub { $ok->(_headers_of($_[0])) },
        sub { $error->($_[1]) },
        { timeout => 30 },
    )->head($url);
}

sub _spawn_process {
    require Plugins::SpotOn::Soloist::Runtime;
    return Plugins::SpotOn::Soloist::Runtime::_spawn_process(@_);
}

sub _set_timer {
    my ($delay, $callback) = @_;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer(
        __PACKAGE__,
        Time::HiRes::time() + $delay,
        sub { $callback->() },
    );
}

1;

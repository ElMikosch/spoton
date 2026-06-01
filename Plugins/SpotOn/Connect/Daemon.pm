package Plugins::SpotOn::Connect::Daemon;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Spec::Functions qw(catdir catfile);
use IO::Select;
use MIME::Base64 qw(encode_base64);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# Disable discovery mode if we have to restart more than x times in y minutes
use constant MAX_FAILURES_BEFORE_DISABLE_DISCOVERY => 3;
use constant MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY => 5 * 60;

# Disable stream mode if the streaming daemon crashes too many times in a short window
use constant MAX_STREAM_FAILURES => 5;
use constant MAX_STREAM_INTERVAL => 2 * 60;

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	name
	cache
	_lastSeen
	_spotifyId
	_proc
	_startTimes
	_streamStartTimes
	_streamMode
	_streamPort
	_stderrFh
) );

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

sub new {
	my ($class, $id) = @_;

	my $self = $class->SUPER::new();

	$self->mac($id);
	$id =~ s/://g;
	$self->id($id);
	$self->_startTimes([]);
	$self->_streamStartTimes([]);
	$self->start();

	return $self;
}

sub start {
	my $self = shift;

	require Proc::Background;

	my $helperPath = Plugins::SpotOn::Helper->get();
	my $client     = Slim::Player::Client::getClient($self->mac);

	unless ($helperPath) {
		$log->warn("SpotOn Connect daemon: no helper binary found, cannot start");
		return;
	}

	unless ($client) {
		$log->warn("SpotOn Connect daemon: no client found for MAC " . $self->mac);
		return;
	}

	# D-11: Use syncname() for synced non-group players; truncate to 60 chars (CON-06)
	$self->name(substr(
		($client->isSynced() && $client->model ne 'group')
			? Slim::Player::Sync::syncname($client)
			: $client->name,
		0, 60
	));

	# Per-account cache dir (same pattern as Plugin.pm::updateTranscodingTable)
	my $activeAccountId = $prefs->client($client)->get('activeAccount')
	                   || $prefs->get('activeAccount')
	                   || '';
	my $cacheDir = $activeAccountId
		? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
		: catdir($serverPrefs->get('cachedir'), 'spoton');
	$self->cache($cacheDir);

	$self->_checkStartTimes();

	my @helperArgs = (
		'-c', $self->cache,
		'-n', $self->name,
		'--disable-audio-cache',
		'--player-mac', $self->mac,
		'--lms', '127.0.0.1:' . $serverPrefs->get('httpport'),
		'--connect',    # SpotOn flag (Spotty-NG used '--connect-stream')
	);

	push @helperArgs, '--disable-discovery' if $prefs->get('disableDiscovery');

	# T-05-08: Log the command BEFORE adding --lms-auth (security: no password in logs)
	if (main::INFOLOG && $log->is_info) {
		$log->info("Starting SpotOn Connect daemon:\n$helperPath " . join(' ', @helperArgs));
	}

	# Add LMS authentication data AFTER the log statement (credentials must not appear in logs)
	if ( $serverPrefs->get('authorize') ) {
		push @helperArgs, '--lms-auth',
			encode_base64(sprintf("%s:%s",
				$serverPrefs->get('username'),
				$serverPrefs->get('password')), '');
	}

	# Pipe for synchronous port capture (CON-16)
	pipe(my $port_r, my $port_w)
		or do { $log->error("pipe() failed for port capture: $!"); return; };

	# D-02: Open stderr log file before spawning — binary eprintln! output captured here
	my $stderrFile = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-connect.log');
	my $stderr_fh;
	open($stderr_fh, '>>', $stderrFile)
		or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderrFile; undef $stderr_fh; };

	eval {
		$self->_proc( Proc::Background->new(
			{ 'die_upon_destroy' => 1, stdout => $port_w,
			  ($stderr_fh ? (stderr => $stderr_fh) : ()) },
			$helperPath,
			@helperArgs,
		) );
	};

	# CRITICAL: close write-end in parent BEFORE IO::Select — otherwise readline blocks forever
	# $stderr_fh intentionally NOT closed — must remain open for lifetime of process
	close($port_w);

	if ($@ || !$self->_proc) {
		$log->warn("Failed to launch SpotOn Connect daemon: $@");
		close($port_r);
		$self->_streamPort(undef);
		return;
	}

	# Store stderr file handle as accessor to prevent premature GC (RESEARCH.md Pitfall 3)
	$self->_stderrFh($stderr_fh) if $stderr_fh;

	# Synchronous port read with 5s timeout (avoids SIGALRM in LMS event loop)
	my $port_line;
	my $sel = IO::Select->new($port_r);
	if ($sel->can_read(5)) {
		$port_line = readline($port_r);
	}
	close($port_r);

	if (!defined $port_line || $port_line !~ /^stream_port=(\d+)/) {
		my $reason = defined $port_line ? "unexpected output: $port_line" : "timeout";
		$log->warn("SpotOn daemon did not announce HTTP stream port ($reason) - aborting");
		$self->_proc->die if $self->_proc && $self->_proc->alive;
		$self->_streamPort(undef);
		return;
	}

	$self->_streamPort($1 + 0);
	$self->_streamMode(1);
	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Connect daemon started, stream port=" . $self->_streamPort
	);
	main::INFOLOG && $log->is_info && $stderrFile && $log->info(
		"SpotOn Connect daemon stderr logged to $stderrFile"
	);
}

sub _checkStartTimes {
	my $self = shift;

	# Crash-backoff: if more than MAX_FAILURES starts recorded within
	# MAX_INTERVAL seconds, disable discovery to prevent infinite crash loops
	if ( scalar @{$self->_startTimes} > MAX_FAILURES_BEFORE_DISABLE_DISCOVERY ) {
		splice @{$self->_startTimes}, 0,
		       @{$self->_startTimes} - MAX_FAILURES_BEFORE_DISABLE_DISCOVERY;

		if ( time() - $self->_startTimes->[0] < MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY
			&& !$prefs->get('disableDiscovery')
		) {
			$log->warn(sprintf(
				'SpotOn daemon crashed %s times within less than %s minutes - disabling discovery.',
				MAX_FAILURES_BEFORE_DISABLE_DISCOVERY,
				MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY / 60
			));

			$prefs->set('disableDiscovery', 1);
		}
	}

	push @{$self->_startTimes}, time();
}

sub _checkStreamStartTimes {
	my $self = shift;

	# Stream-specific crash-backoff: disable stream mode if the daemon crashes too often
	if ( scalar @{$self->_streamStartTimes} >= MAX_STREAM_FAILURES ) {
		splice @{$self->_streamStartTimes}, 0,
		       @{$self->_streamStartTimes} - MAX_STREAM_FAILURES;

		if ( time() - $self->_streamStartTimes->[0] < MAX_STREAM_INTERVAL ) {
			$log->warn(sprintf(
				'SpotOn stream daemon crashed %s times within less than %s minutes - disabling stream mode.',
				MAX_STREAM_FAILURES,
				MAX_STREAM_INTERVAL / 60
			));

			$self->_streamMode(0);
			return 1;
		}
	}

	push @{$self->_streamStartTimes}, time();
	return 0;
}

sub stop {
	my $self = shift;

	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting SpotOn Connect daemon for " . $self->mac);
		$self->_proc->die;
		# No rmtree — SpotOn keeps credentials across restarts (unlike Spotty-NG)
		$self->_streamPort(undef);
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This daemon is dead already... no need to stop it!");
	}
}

sub stopForSync {
	my $self = shift;

	# HTTP mode: plain process kill — no FIFO to preserve.
	# Cache-dir (Spotify credentials) is intentionally NOT removed here.
	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info("Stopping SpotOn Connect daemon for sync: " . $self->mac);
		$self->_proc->die;
		$self->_streamPort(undef);    # clear stale port; start() will set the new one
		$self->_streamStartTimes([]);
		$self->_startTimes([]);
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This daemon is dead already (stopForSync called on dead daemon for " . $self->mac . ")");
	}
}

sub pid {
	my $self = shift;
	return $self->_proc && $self->_proc->pid;
}

sub alive {
	my $self = shift;
	return 1 if $self->_proc && $self->_proc->alive;
}

sub uptime {
	my $self = shift;
	return Time::HiRes::time() - ($self->_startTimes->[-1] || time());
}

1;

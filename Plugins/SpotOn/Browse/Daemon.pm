package Plugins::SpotOn::Browse::Daemon;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use IO::Select;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Disable Browse daemon if it crashes too many times in a short window.
# Browse daemon is simpler than Connect (no discovery mode) — one unified crash-loop check.
use constant MAX_FAILURES_BEFORE_DISABLE => 5;
use constant MAX_INTERVAL_BEFORE_DISABLE => 2 * 60;

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	cache
	_lastSeen
	_startTimes
	_proc
	_browsePort
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
	$self->start();

	return $self;
}

sub start {
	my $self = shift;

	require Proc::Background;

	my $helperPath = Plugins::SpotOn::Helper->get();
	my $client     = Slim::Player::Client::getClient($self->mac);

	unless ($helperPath) {
		$log->warn("SpotOn Browse daemon: no helper binary found, cannot start");
		return;
	}

	unless ($client) {
		$log->warn("SpotOn Browse daemon: no client found for MAC " . $self->mac);
		return;
	}

	# CON-01: Use account-level cache dir for Browse daemon credentials.
	my $activeAccountId = $prefs->get('activeAccount') || '';
	my $cacheDir = $activeAccountId
		? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
		: catdir($serverPrefs->get('cachedir'), 'spoton');
	$self->cache($cacheDir);

	# Clear browse port before attempt (WR-04: stale _browsePort after failed restart)
	$self->_browsePort(undef);

	# Crash-loop check — return early if too many crashes in a short window
	return if $self->_checkStartTimes();

	my @helperArgs = (
		'-c', $self->cache,
		'--browse',
		'--disable-audio-cache',
		'--player-mac', $self->mac,
	);

	# T-28-05: Log the command BEFORE adding any auth args (no credentials in logs)
	if (main::INFOLOG && $log->is_info) {
		$log->info("Starting SpotOn Browse daemon:\n$helperPath " . join(' ', @helperArgs));
	}

	# Browse daemon does not need --lms-auth (no LMS JSON-RPC event dispatch)

	# Pipe for synchronous port capture (CON-16)
	pipe(my $port_r, my $port_w)
		or do { $log->error("pipe() failed for browse port capture: $!"); return; };

	# T-28-07: stderr log only when diagnosticMode is on; /dev/null otherwise
	my $diagMode = $prefs->get('diagnosticMode');
	my $stderrFile;
	my $stderr_fh;
	if ($diagMode) {
		$stderrFile = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-browse.log');
		open($stderr_fh, '>>', $stderrFile)
			or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderr_fh; undef $stderrFile; };
	} else {
		open($stderr_fh, '>', File::Spec->devnull)
			or do { $log->warn("Cannot open /dev/null for stderr: $!"); undef $stderr_fh; };
	}

	# Pitfall 7 (MANDATORY): Temporarily untie STDERR before fork so Proc::Background
	# can dup2 it in the child. LMS ties STDERR to Slim::Utils::Log::Trapper (no OPEN
	# method) — the child would die on 'open STDERR, ">>&N"' dispatch if STDERR remains
	# tied during fork. Untie here (parent only, for the fork window) and re-tie after.
	my $had_stderr_tie = defined tied(*STDERR);
	untie *STDERR if $had_stderr_tie;

	$ENV{RUST_LOG} = $diagMode ? 'spoton=debug,librespot=info' : 'spoton=info,librespot=warn';

	eval {
		$self->_proc( Proc::Background->new(
			{ 'die_upon_destroy' => 1, stdout => $port_w,
			  ($stderr_fh ? (stderr => $stderr_fh) : ()) },
			$helperPath,
			@helperArgs,
		) );
	};

	delete $ENV{RUST_LOG};

	# Re-tie STDERR to LMS log trapper immediately after spawn
	tie *STDERR, 'Slim::Utils::Log::Trapper' if $had_stderr_tie;

	# CRITICAL (Pitfall 5): close write-end in parent BEFORE IO::Select — otherwise
	# readline blocks forever because write-end remains open in parent
	# $stderr_fh intentionally NOT closed — must remain open for lifetime of process
	close($port_w);

	if ($@ || !$self->_proc) {
		$log->warn("Failed to launch SpotOn Browse daemon: $@");
		close($port_r);
		$self->_browsePort(undef);
		return;
	}

	# Store stderr file handle as accessor to prevent premature GC (Pitfall 3)
	$self->_stderrFh($stderr_fh) if $stderr_fh;

	# Synchronous port read with 5s timeout (avoids SIGALRM in LMS event loop)
	my $portWaitStart = Time::HiRes::time();
	my $port_line;
	my $sel = IO::Select->new($port_r);
	if ($sel->can_read(5)) {
		$port_line = readline($port_r);
	}
	close($port_r);

	if (!defined $port_line || $port_line !~ /^browse_port=(\d+)/) {
		my $reason = defined $port_line ? "unexpected output: $port_line" : "timeout";
		$log->warn("SpotOn Browse daemon did not announce HTTP browse port ($reason) - aborting");
		$self->_proc->die if $self->_proc && $self->_proc->alive;
		$self->_browsePort(undef);
		return;
	}

	$self->_browsePort($1 + 0);
	$log->warn(sprintf("[DIAG] browse_port_announce: mac=%s port=%d wait_ms=%.0f",
		$self->mac, $self->_browsePort, (Time::HiRes::time() - $portWaitStart) * 1000))
		if $prefs->get('diagnosticMode');

	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Browse daemon started, browse port=" . $self->_browsePort
	);
	main::INFOLOG && $log->is_info && $stderrFile && $log->info(
		"SpotOn Browse daemon stderr logged to $stderrFile"
	);
	$log->warn("[DIAG] daemon_start: mac=" . $self->mac . " pid=" . ($self->pid || 'unknown')
		. " browse_port=" . $self->_browsePort . " binary=$helperPath")
		if $prefs->get('diagnosticMode');
}

sub _checkStartTimes {
	my $self = shift;

	# T-28-06: Crash-backoff — if more than MAX_FAILURES starts recorded within
	# MAX_INTERVAL seconds, suspend Browse daemon to prevent infinite crash loops.
	# Simpler than Connect::Daemon — no per-player discovery flag, no cooldown timer.
	# DaemonManager::stopHelper will remove the instance; next credential check
	# will restart cleanly after the watchdog fires.
	if ( scalar @{$self->_startTimes} >= MAX_FAILURES_BEFORE_DISABLE ) {
		splice @{$self->_startTimes}, 0,
		       @{$self->_startTimes} - MAX_FAILURES_BEFORE_DISABLE;

		if ( time() - $self->_startTimes->[0] < MAX_INTERVAL_BEFORE_DISABLE ) {
			$log->warn(sprintf(
				'SpotOn Browse daemon crashed %s times within %s minutes - suspending.',
				MAX_FAILURES_BEFORE_DISABLE,
				MAX_INTERVAL_BEFORE_DISABLE / 60
			));
			$log->warn(sprintf("[DIAG] crash_loop_suspend: mac=%s crash_count=%d interval=%ds",
				$self->mac, MAX_FAILURES_BEFORE_DISABLE, time() - $self->_startTimes->[0]))
				if $prefs->get('diagnosticMode');
			return 1;   # caller should abort start()
		}
	}

	push @{$self->_startTimes}, time();
	return 0;
}

sub stop {
	my $self = shift;

	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting SpotOn Browse daemon for " . $self->mac);
		$log->warn("[DIAG] daemon_stop: mac=" . $self->mac . " pid=" . ($self->pid || 'unknown')
			. " uptime=" . sprintf('%.1f', $self->uptime) . "s")
			if $prefs->get('diagnosticMode');
		$self->_proc->die;
		$self->_browsePort(undef);   # Pitfall 4: clear stale port on stop
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This Browse daemon is dead already... no need to stop it!");
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

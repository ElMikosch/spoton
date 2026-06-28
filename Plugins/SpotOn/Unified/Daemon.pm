package Plugins::SpotOn::Unified::Daemon;

use strict;
use warnings;

use base qw(Slim::Utils::Accessor);

use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempfile);
use MIME::Base64 qw(encode_base64);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Disable discovery mode if we have to restart more than x times in y minutes.
# Uses the Connect::Daemon crash-loop pattern (per-player discoveryDisabledByCrashLoop flag).
use constant MAX_FAILURES_BEFORE_DISABLE_DISCOVERY => 3;
use constant MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY => 5 * 60;

# Cooldown duration before re-enabling discovery after crash-loop (D-02: 30 minutes)
use constant DISCOVERY_COOLDOWN_SECONDS => 1800;

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	name
	cache
	_accountId
	_connectEnabled
	_lastSeen
	_proc
	_startTimes
	_streamPort
	_stderrFh
) );

# NOTE: No _streamMode accessor (unified daemon is always streaming when alive)
# NOTE: No _streamStartTimes (single crash-loop check, no separate stream check)
# NOTE: No _spotifyId (not needed for unified mode)

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
		$log->warn("SpotOn Unified daemon: no helper binary found, cannot start");
		return;
	}

	unless ($client) {
		$log->warn("SpotOn Unified daemon: no client found for MAC " . $self->mac);
		return;
	}

	# D-11: Use syncname() for synced non-group players; truncate to 60 chars (CON-06)
	$self->name(substr(
		($client->isSynced() && $client->model ne 'group')
			? Slim::Player::Sync::syncname($client)
			: $client->name,
		0, 60
	));

	# CON-01: Use account-level cache dir for Unified daemon credentials.
	my $activeAccountId = $prefs->get('activeAccount') || '';
	my $cacheDir = $activeAccountId
		? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
		: catdir($serverPrefs->get('cachedir'), 'spoton');
	$self->cache($cacheDir);
	$self->_accountId($activeAccountId);

	# Clear stream port before attempt (WR-04: stale _streamPort after failed restart)
	$self->_streamPort(undef);

	# Crash-loop check — return early if too many crashes in a short window
	$self->_checkStartTimes();

	my @helperArgs = (
		'-c', $self->cache,
		'--unified',
		'--disable-audio-cache',
		'--player-mac', $self->mac,
	);

	# D-07 / D-01: Connect is conditional on per-player toggle.
	# The unified daemon always starts (credential-gated), but --enable-connect
	# is only passed when Spotify Connect is enabled for this player.
	my $connectEnabled = $prefs->client($client)->get('enableSpotifyConnect')
		// $prefs->get('enableSpotifyConnect');
	$self->_connectEnabled($connectEnabled ? 1 : 0);

	if ($connectEnabled) {
		# Spirc device name (required for Connect registration)
		push @helperArgs, '-n', $self->name;
		push @helperArgs, '--enable-connect';
		push @helperArgs, '--lms',
			Slim::Utils::Network::serverAddr() . ':' . $serverPrefs->get('httpport');

		# Per-player discovery flag evaluation (D-05: crash-loop flag overrides user checkbox):
		# 1. discoveryDisabledByCrashLoop per-player (highest priority — crash protection)
		# 2. disableDiscovery per-player          (user checkbox)
		# 3. disableDiscovery global              (fallback for players without per-player pref)
		my $disableDiscovery = ($client && $prefs->client($client)->get('discoveryDisabledByCrashLoop'))
		    || ($client && $prefs->client($client)->get('disableDiscovery'))
		    || $prefs->get('disableDiscovery');
		push @helperArgs, '--disable-discovery' if $disableDiscovery;

		push @helperArgs, '--enable-volume-normalisation' if $prefs->get('normalization');

		# CON-02 / P-50: Volume synchronization at Connect session start.
		# --volume-ctrl linear: matches squeezelite's SoftMixer linear curve so LMS volume
		# maps 1:1 to librespot volume (no logarithmic mismatch).
		# --initial-volume: seeds librespot with the current LMS player volume so the Spotify
		# app shows the correct value immediately (no initial mismatch echo).
		push @helperArgs, '--volume-ctrl', 'linear';
		push @helperArgs, '--initial-volume', int($client->volume // 50);

		# D-09: Pass --autoplay on/off based on per-player pref, gated on binary capability
		if ( Plugins::SpotOn::Helper->getCapability('autoplay') ) {
			my $enableAutoplay = $prefs->client($client)->get('enableAutoplay');
			$enableAutoplay = 1 unless defined $enableAutoplay;  # D-08: default on
			push @helperArgs, '--autoplay', ($enableAutoplay ? 'on' : 'off');
		}
	}

	# T-29-07: Log the command BEFORE adding --lms-auth (security: no credentials in logs)
	if (main::INFOLOG && $log->is_info) {
		$log->info("Starting SpotOn Unified daemon:\n$helperPath " . join(' ', @helperArgs));
	}

	# Add LMS authentication data AFTER the log statement (credentials must not appear in logs)
	if ($connectEnabled && $serverPrefs->get('authorize')) {
		push @helperArgs, '--lms-auth',
			encode_base64(sprintf("%s:%s",
				$serverPrefs->get('username'),
				$serverPrefs->get('password')), '');
	}

	# Tempfile for synchronous port capture (cross-platform: IO::Select on pipes
	# fails on Windows where select() only works on sockets).
	my ($port_fh, $port_tmpfile);
	eval {
		($port_fh, $port_tmpfile) = tempfile('spoton-port-XXXX',
			DIR => catdir($serverPrefs->get('cachedir'), 'spoton'),
			UNLINK => 0,
		);
	};
	if ($@ || !$port_tmpfile) {
		$log->error("tempfile() failed for port capture: $@");
		if ($INC{'Plugins/SpotOn/Status.pm'}) {
			Plugins::SpotOn::Status->recordError('error', 'Daemon', "tempfile failed: $@");
		}
		return;
	}

	# T-29-09: stderr log only when diagnosticMode is on; /dev/null otherwise.
	# Append mode (>>) matches Browse::Daemon pattern — preserves logs across restarts.
	my $diagMode = $prefs->get('diagnosticMode');
	my $stderrFile;
	my $stderr_fh;
	if ($diagMode) {
		$stderrFile = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-unified.log');
		open($stderr_fh, '>>', $stderrFile)
			or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderr_fh; undef $stderrFile; };
	} else {
		open($stderr_fh, '>', File::Spec->devnull)
			or do { $log->warn("Cannot open /dev/null for stderr: $!"); undef $stderr_fh; };
	}

	# T-29-09 / Pitfall 7 (MANDATORY): Temporarily untie STDERR before fork so
	# Proc::Background can dup2 it in the child. LMS ties STDERR to
	# Slim::Utils::Log::Trapper (no OPEN method) — the child would die on
	# 'open STDERR, ">>&N"' dispatch if STDERR remains tied during fork.
	# Untie here (parent only, for the fork window) and re-tie immediately after spawn.
	my $had_stderr_tie = defined tied(*STDERR);
	untie *STDERR if $had_stderr_tie;

	$ENV{RUST_LOG} = $diagMode ? 'spoton=debug,librespot=info' : 'spoton=info,librespot=warn';

	close($port_fh);

	# SPOTON_PORT_FILE: tell the daemon to write its port to a file directly.
	# Always set as primary mechanism — Proc::Background stdout redirect
	# fails in Docker/s6 and Windows service environments.
	$ENV{SPOTON_PORT_FILE} = $port_tmpfile;
	# SPOTON_LOG_FILE only when Proc::Background can't redirect stderr
	$ENV{SPOTON_LOG_FILE} = $stderrFile if $stderrFile && main::ISWINDOWS;

	eval {
		$self->_proc( Proc::Background->new(
			{ 'die_upon_destroy' => 1,
			  (main::ISWINDOWS ? () : (stdout => $port_tmpfile)),
			  ($stderr_fh && !main::ISWINDOWS ? (stderr => $stderr_fh) : ()) },
			$helperPath,
			@helperArgs,
		) );
	};

	delete $ENV{SPOTON_PORT_FILE};
	delete $ENV{SPOTON_LOG_FILE};

	delete $ENV{RUST_LOG};

	# Re-tie STDERR to LMS log trapper immediately after spawn
	tie *STDERR, 'Slim::Utils::Log::Trapper' if $had_stderr_tie;

	if ($@ || !$self->_proc) {
		$log->warn("Failed to launch SpotOn Unified daemon: $@");
		unlink $port_tmpfile;
		$self->_streamPort(undef);
		return;
	}

	# Store stderr file handle as accessor to prevent premature GC (Pitfall 3)
	$self->_stderrFh($stderr_fh) if $stderr_fh;

	# Poll tempfile for port announcement (cross-platform, 5s timeout).
	# Unified daemon writes stream_port=N to stdout which Proc::Background
	# redirects to the tempfile.
	my $portWaitStart = Time::HiRes::time();
	my $port_line;
	for (1..50) {
		if (-s $port_tmpfile) {
			if (open(my $pfh, '<', $port_tmpfile)) {
				$port_line = readline($pfh);
				close($pfh);
				last if defined $port_line && $port_line =~ /stream_port=\d+\s*$/;
				undef $port_line;
			}
		}
		last unless $self->_proc && $self->_proc->alive;
		Time::HiRes::usleep(100_000);
	}
	# Clean up tempfile. On Windows the daemon may still hold the FD open
	# (no POSIX unlink semantics), so unlink can fail — stale files are
	# cleaned up on next daemon start via the glob below.
	unlink $port_tmpfile;
	for my $stale (glob(catfile(catdir($serverPrefs->get('cachedir'), 'spoton'), 'spoton-port-*'))) {
		unlink $stale;
	}

	if (!defined $port_line || $port_line !~ /^stream_port=(\d+)/) {
		my $reason = defined $port_line ? "unexpected output: $port_line" : "timeout";
		$log->warn("SpotOn Unified daemon did not announce HTTP stream port ($reason) - aborting");
		$self->_proc->die if $self->_proc && $self->_proc->alive;
		$self->_streamPort(undef);
		return;
	}

	$self->_streamPort($1 + 0);
	$log->warn(sprintf("[DIAG] unified_port_announce: mac=%s port=%d wait_ms=%.0f",
		$self->mac, $self->_streamPort, (Time::HiRes::time() - $portWaitStart) * 1000))
		if $prefs->get('diagnosticMode');

	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Unified daemon started, stream port=" . $self->_streamPort
	);
	main::INFOLOG && $log->is_info && $stderrFile && $log->info(
		"SpotOn Unified daemon stderr logged to $stderrFile"
	);
	$log->warn("[DIAG] daemon_start: mac=" . $self->mac . " pid=" . ($self->pid || 'unknown')
		. " stream_port=" . $self->_streamPort . " name=" . $self->name
		. " binary=$helperPath connect_enabled=" . ($connectEnabled ? 1 : 0))
		if $prefs->get('diagnosticMode');
}

sub _checkStartTimes {
	my $self = shift;

	# Crash-backoff: if more than MAX_FAILURES starts recorded within
	# MAX_INTERVAL seconds, disable discovery to prevent infinite crash loops.
	# Per-player scope: sets discoveryDisabledByCrashLoop on the player's prefs,
	# NOT the global disableDiscovery flag (D-05: crash-loop separate from user checkbox).
	if ( scalar @{$self->_startTimes} >= MAX_FAILURES_BEFORE_DISABLE_DISCOVERY ) {
		splice @{$self->_startTimes}, 0,
		       @{$self->_startTimes} - MAX_FAILURES_BEFORE_DISABLE_DISCOVERY;

		if ( time() - $self->_startTimes->[0] < MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY ) {
			my $client  = Slim::Player::Client::getClient($self->mac);
			my $already = $client
				? ($prefs->client($client)->get('discoveryDisabledByCrashLoop') || 0)
				: ($prefs->get('disableDiscovery') || 0);

			unless ($already) {
				$log->warn(sprintf(
					'SpotOn Unified daemon crashed %s times within less than %s minutes - disabling discovery for %s min.',
					MAX_FAILURES_BEFORE_DISABLE_DISCOVERY,
					MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY / 60,
					DISCOVERY_COOLDOWN_SECONDS / 60
				));
				$log->warn(sprintf("[DIAG] crash_loop_disable: mac=%s crash_count=%d interval=%ds cooldown=%ds",
					$self->mac, MAX_FAILURES_BEFORE_DISABLE_DISCOVERY,
					time() - $self->_startTimes->[0], DISCOVERY_COOLDOWN_SECONDS))
					if $prefs->get('diagnosticMode');

				if ($client) {
					# Per-player crash-loop flag (D-05: separate from user disableDiscovery checkbox)
					$prefs->client($client)->set('discoveryDisabledByCrashLoop', 1);
				}
				else {
					# Fallback: no client object — use global flag
					$prefs->set('disableDiscovery', 1);
				}

				# D-03: Schedule cooldown timer for auto-reset after 30 minutes
				Slim::Utils::Timers::killTimers($self->mac, \&_resetDiscoveryCooldown);
				Slim::Utils::Timers::setTimer(
					$self->mac,
					Time::HiRes::time() + DISCOVERY_COOLDOWN_SECONDS,
					\&_resetDiscoveryCooldown,
					$self->mac
				);
			}
		}
	}

	push @{$self->_startTimes}, time();
}

# D-03: Timer callback — resets crash-loop flag and restarts daemon after cooldown expires.
# Timer fires as: _resetDiscoveryCooldown($unused_timer_arg, $mac)
sub _resetDiscoveryCooldown {
	my (undef, $mac) = @_;

	my $client = Slim::Player::Client::getClient($mac);
	unless ($client) {
		$log->warn("Discovery cooldown expired for $mac but no client found - skipping reset");
		return;
	}

	main::INFOLOG && $log->is_info && $log->info(
		"Discovery cooldown expired for $mac -- re-enabling and restarting Unified daemon"
	);

	$prefs->client($client)->set('discoveryDisabledByCrashLoop', 0);
	$log->warn("[DIAG] crash_loop_reset: mac=$mac discovery_re_enabled=1")
		if $prefs->get('diagnosticMode');

	require Plugins::SpotOn::Unified::DaemonManager;
	Plugins::SpotOn::Unified::DaemonManager->stopHelper($client);
	Plugins::SpotOn::Unified::DaemonManager->startHelper($client);
}

sub stop {
	my $self = shift;

	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info(
			"Quitting SpotOn Unified daemon for " . $self->mac
		);
		$log->warn("[DIAG] daemon_stop: mac=" . $self->mac . " pid=" . ($self->pid || 'unknown')
			. " uptime=" . sprintf('%.1f', $self->uptime) . "s")
			if $prefs->get('diagnosticMode');
		$self->_proc->die;
		$self->_streamPort(undef);
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This Unified daemon is dead already... no need to stop it!");
	}
}

sub stopForSync {
	my $self = shift;

	# HTTP mode: plain process kill — no FIFO to preserve.
	# Cache-dir (Spotify credentials) is intentionally NOT removed here.
	# Reset _startTimes so crash-loop backoff is cleared for the clean sync restart.
	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info(
			"Stopping SpotOn Unified daemon for sync: " . $self->mac
		);
		$self->_proc->die;
		$self->_streamPort(undef);    # clear stale port; start() will set the new one
		$self->_startTimes([]);
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This Unified daemon is dead already (stopForSync called on dead daemon for "
			. $self->mac . ")");
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

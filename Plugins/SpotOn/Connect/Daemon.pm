package Plugins::SpotOn::Connect::Daemon;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use IO::Select;
use MIME::Base64 qw(encode_base64);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Disable discovery mode if we have to restart more than x times in y minutes
use constant MAX_FAILURES_BEFORE_DISABLE_DISCOVERY => 3;
use constant MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY => 5 * 60;

# Cooldown duration before re-enabling discovery after crash-loop (D-02: 30 minutes)
use constant DISCOVERY_COOLDOWN_SECONDS => 1800;

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

	# CON-01: Use account-level cache dir for Connect daemon credentials.
	# ZeroConf reconnect uses Session(None) in Rust to prevent credential overwrite.
	my $activeAccountId = $prefs->get('activeAccount') || '';
	my $cacheDir = $activeAccountId
		? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
		: catdir($serverPrefs->get('cachedir'), 'spoton');
	$self->cache($cacheDir);

	# Reset stream state before attempt (WR-04: stale _streamMode after failed restart)
	$self->_streamMode(0);
	$self->_streamPort(undef);

	$self->_checkStartTimes();
	$self->_checkStreamStartTimes();

	my @helperArgs = (
		'-c', $self->cache,
		'-n', $self->name,
		'--disable-audio-cache',
		'--player-mac', $self->mac,
		'--lms', Slim::Utils::Network::serverAddr() . ':' . $serverPrefs->get('httpport'),
		'--connect',    # SpotOn flag (Spotty-NG used '--connect-stream')
	);

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

	# D-02: stderr log only when diagnosticMode is on; /dev/null otherwise
	my $diagMode = $prefs->get('diagnosticMode');
	my $stderr_fh;
	if ($diagMode) {
		my $stderrFile = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-connect.log');
		open($stderr_fh, '>', $stderrFile)
			or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderr_fh; };
	} else {
		open($stderr_fh, '>', File::Spec->devnull)
			or do { $log->warn("Cannot open /dev/null for stderr: $!"); undef $stderr_fh; };
	}

	# Temporarily untie STDERR before fork so Proc::Background can dup2 it in the child.
	# LMS ties STDERR to Slim::Utils::Log::Trapper (no OPEN method) — the child would die on
	# 'open STDERR, ">>&N"' dispatch if STDERR remains tied during fork.
	# We untie here (parent only, for the fork window) and re-tie immediately after spawn.
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
	my $portWaitStart = Time::HiRes::time();
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
	$log->warn(sprintf("[DIAG] daemon_port_announce: mac=%s port=%d wait_ms=%.0f", $self->mac, $self->_streamPort, (Time::HiRes::time() - $portWaitStart) * 1000)) if $prefs->get('diagnosticMode');
	$self->_streamMode(1);
	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Connect daemon started, stream port=" . $self->_streamPort
	);
	main::INFOLOG && $log->is_info && $stderrFile && $log->info(
		"SpotOn Connect daemon stderr logged to $stderrFile"
	);
	$log->warn("[DIAG] daemon_start: mac=" . $self->mac . " pid=" . ($self->pid || 'unknown') . " stream_port=" . $self->_streamPort . " name=" . $self->name . " binary=$helperPath discovery_disabled=" . ($disableDiscovery ? 1 : 0)) if $prefs->get('diagnosticMode');
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
					'SpotOn daemon crashed %s times within less than %s minutes - disabling discovery for %s min.',
					MAX_FAILURES_BEFORE_DISABLE_DISCOVERY,
					MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY / 60,
					DISCOVERY_COOLDOWN_SECONDS / 60
				));
				$log->warn(sprintf("[DIAG] crash_loop_disable: mac=%s crash_count=%d interval=%ds cooldown=%ds", $self->mac, MAX_FAILURES_BEFORE_DISABLE_DISCOVERY, time() - $self->_startTimes->[0], DISCOVERY_COOLDOWN_SECONDS)) if $prefs->get('diagnosticMode');

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
		"Discovery cooldown expired for $mac -- re-enabling and restarting daemon"
	);

	$prefs->client($client)->set('discoveryDisabledByCrashLoop', 0);
	$log->warn("[DIAG] crash_loop_reset: mac=$mac discovery_re_enabled=1") if $prefs->get('diagnosticMode');

	require Plugins::SpotOn::Connect::DaemonManager;
	Plugins::SpotOn::Connect::DaemonManager->stopHelper($client);
	Plugins::SpotOn::Connect::DaemonManager->startHelper($client);
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
		$log->warn("[DIAG] daemon_stop: mac=" . $self->mac . " pid=" . ($self->pid || 'unknown') . " uptime=" . sprintf('%.1f', $self->uptime) . "s") if $prefs->get('diagnosticMode');
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

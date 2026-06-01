package Plugins::SpotOn::Connect;

use strict;

use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use Time::HiRes;

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

# Seconds; delta threshold to trigger a seek on change events
use constant SEEK_THRESHOLD => 3;

# Fallback artwork for stream-mode metadata updates
use constant IMG_TRACK => '/html/images/cover.png';

# Seconds; CON-11 — ignore volume events within this window after daemon start.
# The binary's suppress_next_volume AtomicBool handles the very first VolumeChanged after
# SessionConnected. This grace period suppresses subsequent echoes during session setup.
use constant VOLUME_GRACE_PERIOD => 20;

# Seconds; suppress spurious stop events during session setup (mid-playback transfer)
use constant CONNECT_START_GRACE => 12;

# Volume debounce: merge rapid volume events into one (0.5s window)
use constant VOLUME_DEBOUNCE => 0.5;

# Seek debounce: coalesce rapid seek events (0.3s window)
use constant SEEK_DEBOUNCE => 0.3;

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

my $initialized;

# Track the MAC of the player currently owning the active Connect session.
# Used by _onPause to suppress stale stop events from old players when switching.
my $_activeConnectPlayer;

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub init {
    my ($class) = @_;

    return if $initialized;

    #                                                                |requires Client
    #                                                                |  |is a Query
    #                                                                |  |  |has Tags
    #                                                                |  |  |  |Function to call
    #                                                                C  Q  T  F
    Slim::Control::Request::addDispatch(['spottyconnect', '_cmd'],
                                                            [1, 0, 1, \&_connectEvent]
    );

    # Listen to playlist change events so we know when Spotify Connect mode ends
    Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);

    # Forward local pause/stop to the Spotify controller for bidirectional state sync
    Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);

    # Forward local volume changes to Spotify for bidirectional state sync
    Slim::Control::Request::subscribe(\&_onVolume, [['mixer'], ['volume']]);

    # Forward local seeks to Spotify so the app stays in sync
    Slim::Control::Request::subscribe(\&_onSeek, [['time']]);

    # Forward local skip next/prev to Spotify instead of letting LMS handle it
    Slim::Control::Request::subscribe(\&_onPlaylistJump, [['playlist'], ['jump', 'index']]);

    require Plugins::SpotOn::Connect::DaemonManager;
    Plugins::SpotOn::Connect::DaemonManager->init();

    $initialized = 1;
}

# isSpotifyConnect($class, $client)
# Returns true if the given player is currently in active Spotify Connect mode.
# Used by ProtocolHandler to disable LMS seek in stream mode.
sub isSpotifyConnect {
    my ($class, $client) = @_;

    return unless $client;
    $client = $client->master if $client->can('master');

    return $_activeConnectPlayer && $_activeConnectPlayer eq $client->id ? 1 : 0;
}

# shutdown($class)
# Cleanly unsubscribes all event handlers and stops all Connect daemons.
sub shutdown {
    if ($initialized) {
        require Plugins::SpotOn::Connect::DaemonManager;
        Plugins::SpotOn::Connect::DaemonManager->shutdown();

        Slim::Control::Request::unsubscribe(\&_onNewSong);
        Slim::Control::Request::unsubscribe(\&_onPause);
        Slim::Control::Request::unsubscribe(\&_onVolume);
        Slim::Control::Request::unsubscribe(\&_onSeek);
        Slim::Control::Request::unsubscribe(\&_onPlaylistJump);

        $_activeConnectPlayer = undef;
        $initialized = 0;
    }
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# _isStreamMode($client)
# Returns true if the Connect daemon for this client is in HTTP stream mode.
sub _isStreamMode {
    my ($client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');
    require Plugins::SpotOn::Connect::DaemonManager;
    my $helper = Plugins::SpotOn::Connect::DaemonManager->helperForClient($client->id);
    return $helper && $helper->_streamMode;
}

# _stopConnectDaemon($class, $client)
# Stops the active Connect daemon for this client (D-08: Browse→Connect mutual exclusion).
# Called when Browse starts on a player that has an active Connect session.
sub _stopConnectDaemon {
    my ($class, $client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');

    main::INFOLOG && $log->is_info && $log->info(
        "D-08 mutual exclusion: stopping Connect daemon for Browse start on " . $client->id
    );

    require Plugins::SpotOn::Connect::DaemonManager;
    Plugins::SpotOn::Connect::DaemonManager->stopHelper($client->id);

    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        $_activeConnectPlayer = undef;
    }
}

# _sendControlCommand($client, $endpoint, $body_hashref)
# Sends an HTTP control command to the binary's /control/* endpoint (D-14).
# Falls back to Spotify Web API via API::Client if binary unreachable (D-15).
sub _sendControlCommand {
    my ($client, $endpoint, $body) = @_;
    return unless $client;

    require Plugins::SpotOn::Connect::DaemonManager;
    my $port = Plugins::SpotOn::Connect::DaemonManager->streamPortForClient($client->id);
    unless ($port) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: no stream port for " . $client->id . ", skipping $endpoint"
        );
        return;
    }

    my $url      = "http://127.0.0.1:$port$endpoint";
    my $jsonBody = $body ? eval { to_json($body) } : '{}';

    main::INFOLOG && $log->is_info && $log->info(
        "_sendControlCommand: POST $url ($jsonBody)"
    );

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("_sendControlCommand: $endpoint OK");
        },
        sub {
            my ($http, $error) = @_;
            main::INFOLOG && $log->is_info && $log->info(
                "_sendControlCommand: $endpoint failed ($error) — trying Web API fallback (D-15)"
            );
            _sendControlFallback($client, $endpoint, $body);
        },
        { timeout => 5 }
    );

    $http->post($url, 'Content-Type' => 'application/json', $jsonBody);
}

# _sendControlFallback($client, $endpoint, $body)
# D-15: Spotify Web API fallback when binary control endpoint is unreachable.
sub _sendControlFallback {
    my ($client, $endpoint, $body) = @_;
    require Plugins::SpotOn::API::Client;

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';

    if ($endpoint eq '/control/pause') {
        Plugins::SpotOn::API::Client->playerPause($accountId, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API pause fallback done");
        });
    }
    elsif ($endpoint eq '/control/play') {
        Plugins::SpotOn::API::Client->playerPlay($accountId, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API play fallback done");
        });
    }
    elsif ($endpoint eq '/control/volume' && $body && defined $body->{volume}) {
        Plugins::SpotOn::API::Client->playerVolume($accountId, $body->{volume}, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API volume fallback done");
        });
    }
    elsif ($endpoint eq '/control/seek' && $body && defined $body->{position_ms}) {
        my $positionMs = $body->{position_ms};
        Plugins::SpotOn::API::Client->playerSeek($accountId, $positionMs, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API seek fallback done");
        });
    }
}

# ---------------------------------------------------------------------------
# Event subscribers (LMS → Binary direction, D-14)
# ---------------------------------------------------------------------------

# _onNewSong($request)
# Handles CON-17: when a Connect session triggers a new LMS track, apply
# previously-stored progress offset so playback resumes at the correct position.
sub _onNewSong {
    my $request = shift;

    # Source-marking loop prevention: skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    # CON-17: Apply stored progress for Connect sessions
    if (__PACKAGE__->isSpotifyConnect($client)) {
        if (my $progress = $client->pluginData('progress')) {
            $client->pluginData(progress => 0);

            if (_isStreamMode($client)) {
                # Stream-mode: binary streams from current position. Adjust
                # startOffset so songTime reports the correct position without
                # triggering _JumpToTime → _Stop + _Stream.
                my $song = $client->playingSong();
                if ($song) {
                    my $elapsed = $client->songElapsedSeconds() || 0;
                    $song->startOffset(int($progress) - $elapsed);
                    main::INFOLOG && $log->is_info && $log->info(
                        "Stream mode mid-song connect: startOffset=" . $song->startOffset()
                    );
                }
            } else {
                my $seekReq = Slim::Control::Request->new($client->id, ['time', int($progress)]);
                $seekReq->source(__PACKAGE__);
                $seekReq->execute();
            }
        }
        return;
    }

    # If Connect flag was set but we're no longer in a Connect URL, clear state
    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        my $song = $client->playingSong();
        my $url  = $song ? ($song->streamUrl || '') : '';
        unless ($url =~ m{spotify://connect-}) {
            main::INFOLOG && $log->is_info && $log->info(
                "New song without Connect URL — clearing active Connect state for " . $client->id
            );
            $_activeConnectPlayer = undef;
        }
    }
}

# _onPause($request)
# Forwards LMS pause/stop events to the binary's HTTP control endpoint (D-14).
sub _onPause {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $isUnpause = $request->isCommand([['playlist'], ['pause']]) && !$request->getParam('_newvalue');

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    # Echo suppression: _connectEvent's ['pause', 0/1] triggers a playlist
    # notification without source-marking. Suppress within 1s of our last
    # _connectEvent-initiated pause to prevent spirc.pause()/play() echo.
    my $lastConnectPause = $client->pluginData('connectPauseTs') || 0;
    if (Time::HiRes::time() - $lastConnectPause < 1) {
        main::INFOLOG && $log->is_info && $log->info(
            "Suppressing _onPause echo from _connectEvent (within 1s)"
        );
        return;
    }

    # Grace period: suppress stop/pause events within 3s of our own playlist play.
    # When Connect issues playlist play, LMS internally stops the previous item
    # which generates a stop event that would leak back to the binary as /control/pause.
    my $startTime = $client->pluginData('connectStartTime') || 0;
    if (Time::HiRes::time() - $startTime < 3) {
        main::INFOLOG && $log->is_info && $log->info(
            "Suppressing pause/stop during Connect start grace period"
        );
        return;
    }

    # Player-switch guard: if another player has taken over the active Connect
    # session, suppress this player's stop event.
    if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
        main::INFOLOG && $log->is_info && $log->info(
            "Ignoring stop/pause from " . $client->id . " - active Connect player is $_activeConnectPlayer"
        );
        return;
    }

    if ($isUnpause) {
        main::INFOLOG && $log->is_info && $log->info(
            "Got unpause event - forwarding to Connect binary via HTTP /control/play (D-14)"
        );
        _sendControlCommand($client, '/control/play', undef);
    } else {
        main::INFOLOG && $log->is_info && $log->info(
            "Got a pause event - forwarding to Connect binary via HTTP /control/pause (D-14)"
        );
        _sendControlCommand($client, '/control/pause', undef);
    }
}

# _onVolume($request)
# Forwards LMS volume changes to binary /control/volume with 0.5s debounce (D-14).
sub _onVolume {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    my $volume = $client->volume;

    # Debounce: merge rapid volume events into one (0.5s window)
    Slim::Utils::Timers::killTimers($client, \&_bufferedSetVolume);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + VOLUME_DEBOUNCE, \&_bufferedSetVolume, $volume);
}

sub _bufferedSetVolume {
    my ($client, $volume) = @_;

    main::INFOLOG && $log->is_info && $log->info(
        "Forwarding volume to Connect binary: $volume (D-14)"
    );

    _sendControlCommand($client, '/control/volume', { volume => int($volume) });
}

# _onSeek($request)
# Forwards LMS seek events to binary /control/seek with 0.3s debounce (D-14).
sub _onSeek {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    my $position = Slim::Player::Source::songTime($client) || 0;
    my $positionMs = int($position * 1000);

    # Debounce: coalesce rapid seek events (0.3s window)
    Slim::Utils::Timers::killTimers($client, \&_bufferedSeek);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DEBOUNCE, \&_bufferedSeek, $positionMs);
}

sub _bufferedSeek {
    my ($client, $positionMs) = @_;

    main::INFOLOG && $log->is_info && $log->info(
        "Forwarding seek to Connect binary: ${positionMs}ms (D-14)"
    );

    _sendControlCommand($client, '/control/seek', { position_ms => $positionMs });
}

# _onPlaylistJump($request)
# Forwards LMS skip next/prev events to binary /control/next or /control/prev (D-14).
sub _onPlaylistJump {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    my $index = $request->getParam('_index');
    return if !defined $index;

    if ($index eq '+1') {
        main::INFOLOG && $log->is_info && $log->info(
            "Connect mode: forwarding skip-next to binary /control/next (D-14)"
        );
        _sendControlCommand($client, '/control/next', undef);
    }
    elsif ($index eq '-1' || $index eq '+0') {
        main::INFOLOG && $log->is_info && $log->info(
            "Connect mode: forwarding skip-previous to binary /control/prev (D-14)"
        );
        _sendControlCommand($client, '/control/prev', undef);
    }
}

# ---------------------------------------------------------------------------
# spottyconnect JSON-RPC dispatch handler (Binary → LMS direction, CON-03)
#
# Wire vocabulary (librespot-spoton connect.rs):
#   start  — new track begins (None -> Some);  p1=track_id(base62), p2=""
#   change — track changes mid-playback;        p1=new_track_id, p2=previous_track_id
#   stop   — PlayerEvent::Paused OR Stopped;    p1="", p2=""  (NOTE: no 'pause' event)
#   volume — VolumeChanged (after suppress);    p1=volume 0-100, p2=""
#   seek   — Seeked mid-playback;               p1=position in seconds (3 decimals), p2=""
#   resume — Playing after Pause (same track); p1=track_id(base62), p2=position (seconds, 3 decimals)
# ---------------------------------------------------------------------------
sub _connectEvent {
    my $request = shift;
    my $client  = $request->client()->master;

    my $cmd = $request->getParam('_cmd');

    main::INFOLOG && $log->is_info && $log->info(sprintf(
        'Got spottyconnect event for %s: %s', $client->id, $cmd
    ));

    # Claim active Connect ownership on 'start' (must be synchronous, before async ops)
    if ($cmd eq 'start') {
        $client->pluginData(pendingConnect => 1);

        # If another player had Connect, clear its state
        if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
            my $oldClient = Slim::Player::Client::getClient($_activeConnectPlayer);
            if ($oldClient) {
                $oldClient = $oldClient->master;
                main::INFOLOG && $log->is_info && $log->info(
                    "Player switch: clearing Connect on " . $_activeConnectPlayer . " for " . $client->id
                );
            }
        }

        $_activeConnectPlayer = $client->id;
    }

    # -----------------------------------------------------------------
    # Volume handler (CON-11): check grace period before forwarding
    # -----------------------------------------------------------------
    if ($cmd eq 'volume') {
        # Skip source-marked requests (would be from our own _onVolume, not from binary)
        return if $request->source && $request->source eq __PACKAGE__;

        my $volume = $request->getParam('_p2');
        return unless defined $volume && $volume ne '';

        # CON-11: VOLUME_GRACE_PERIOD — ignore volume events within the first N seconds
        # after daemon start. The binary's suppress_next_volume AtomicBool handles the very
        # first VolumeChanged; this grace period covers subsequent echoes during session setup.
        require Plugins::SpotOn::Connect::DaemonManager;
        if (Plugins::SpotOn::Connect::DaemonManager->uptime($client->id) < VOLUME_GRACE_PERIOD) {
            main::INFOLOG && $log->is_info && $log->info(
                "Ignoring initial volume reset right after daemon start (CON-11 grace period)"
            );
            return;
        }

        main::INFOLOG && $log->is_info && $log->info("Binary reported volume change: $volume");

        # Source-mark to prevent _onVolume from echoing back to binary (T-05-13)
        my $volReq = Slim::Control::Request->new($client->id, ['mixer', 'volume', $volume]);
        $volReq->source(__PACKAGE__);
        $volReq->execute();
        return;
    }

    # -----------------------------------------------------------------
    # Seek handler (CON-13): always use startOffset, NEVER ['time', N] in stream mode
    # -----------------------------------------------------------------
    if ($cmd eq 'seek') {
        my $position = $request->getParam('_p2');
        if (defined $position && $position ne '') {
            main::INFOLOG && $log->is_info && $log->info("Binary reported seek to: $position");

            if ($client->pluginData('pendingConnect')) {
                # Seek arrived before playlist play — store for _onNewSong to apply
                # AFTER the new song object is created (CON-17 race prevention)
                $client->pluginData(progress => $position);
                $client->pluginData(pendingConnect => 0);
                main::INFOLOG && $log->is_info && $log->info(
                    "Stream mode seek deferred: progress=$position (pending connect)"
                );
            } else {
                # CON-13: Use startOffset to adjust position without triggering
                # _JumpToTime → _Stop + _Stream (which would restart the HTTP stream)
                my $song = $client->playingSong();
                if ($song) {
                    my $elapsed = $client->songElapsedSeconds() || 0;
                    $song->startOffset(int($position) - $elapsed);
                    main::INFOLOG && $log->is_info && $log->info(
                        "Stream mode seek: adjusted startOffset to " . $song->startOffset()
                    );
                }
            }
        }
        return;
    }

    # -----------------------------------------------------------------
    # Resume handler (CON-05, D-02): binary sends resume notify after Pause->Playing
    # transition on same track. Unpauses squeezelite via ['pause', 0] (source-marked
    # to prevent _onPause echo, T-05-13). Adjusts startOffset per CON-13.
    # -----------------------------------------------------------------
    if ($cmd eq 'resume') {
        my $trackId  = $request->getParam('_p2');
        my $position = $request->getParam('_p3');

        return unless __PACKAGE__->isSpotifyConnect($client);

        main::INFOLOG && $log->is_info && $log->info(
            "Resume event: trackId=$trackId position=$position"
        );

        # Unpause squeezelite — CRITICAL: use ['pause', 0] NOT ['play'].
        # ['play'] would open a new HTTP stream connection and break the
        # continuous PCM stream (Pitfall 1). Source-mark for T-05-13 loop prevention.
        $client->pluginData(connectPauseTs => Time::HiRes::time());
        my $unPauseReq = Slim::Control::Request->new($client->id, ['pause', 0]);
        $unPauseReq->source(__PACKAGE__);
        $unPauseReq->execute();

        # CON-13: Sync position via startOffset — NEVER use ['time', N] in stream mode.
        # startOffset adjusts songTime without triggering _JumpToTime -> _Stop + _Stream.
        if (defined $position && $position ne '') {
            my $song = $client->playingSong();
            if ($song) {
                my $elapsed = $client->songElapsedSeconds() || 0;
                $song->startOffset(int($position) - $elapsed);
                main::INFOLOG && $log->is_info && $log->info(
                    "Resume: adjusted startOffset to " . $song->startOffset()
                );
            }
        }

        return;
    }

    # -----------------------------------------------------------------
    # Ignore stop events during initial new-track window (newTrack flag prevents
    # race between start event processing and LMS stop-before-play sequence)
    # -----------------------------------------------------------------
    if ($cmd eq 'stop' && $client->pluginData('newTrack')) {
        main::INFOLOG && $log->is_info && $log->info(
            "Ignoring stop event while starting new track"
        );
        return;
    }

    # -----------------------------------------------------------------
    # Start: issue playlist play with spotify://connect-<ts> URL
    # (CON-17: progress stored BEFORE playlist play command)
    # -----------------------------------------------------------------
    if ($cmd eq 'start') {
        my $trackId = $request->getParam('_p2');

        # Clear echo suppression — new track start is authoritative
        $client->pluginData(connectPauseTs => 0);

        # D-08 mutual exclusion: stop any Browse playback on this player
        my $song = $client->playingSong();
        my $currentUrl = $song ? ($song->streamUrl || '') : '';
        if ($currentUrl =~ m{^spotify://} && $currentUrl !~ m{spotify://connect-}) {
            main::INFOLOG && $log->is_info && $log->info(
                "D-08: Connect start stopping Browse playback on " . $client->id
            );
            my $stopReq = Slim::Control::Request->new($client->id, ['stop']);
            $stopReq->source(__PACKAGE__);
            $stopReq->execute();
        }

        # Mark new track in progress (prevents premature newsong handling)
        $client->pluginData(newTrack => 1);
        $client->pluginData(connectStartTime => Time::HiRes::time());

        # CON-17: store progress from initial seek event (already set in 'seek' handler above)
        # The progress is stored in pluginData BEFORE we issue playlist play.
        # _onNewSong will read and apply it after the new Song object is created.

        # Stale-API-fallback: if API returns no track, use the binary's track_id
        if ($trackId) {
            $client->pluginData(eventTrackUri => "spotify:track:$trackId");
        }

        # The spotify://connect-<ts> URL signals Connect mode to ProtocolHandler.pm
        # which returns 'soc' from formatOverride() and provides canDirectStream URL.
        my $ts      = int(Time::HiRes::time() * 1000);
        my $playReq = $client->execute([
            'playlist', 'play',
            sprintf("spotify://connect-%u", $ts)
        ]);
        $playReq->source(__PACKAGE__);

        $client->pluginData(pendingConnect => 0);

        # Fetch metadata for NowPlaying display via API::Client (D-13)
        if ($trackId) {
            _fetchTrackMetadata($client, $trackId);
        }

        return;
    }

    # -----------------------------------------------------------------
    # Change: track changed mid-playback (stream continues, metadata updates)
    # -----------------------------------------------------------------
    if ($cmd eq 'change') {
        my $newTrackId  = $request->getParam('_p2');
        my $prevTrackId = $request->getParam('_p3');

        # Clear echo suppression — track change is authoritative
        $client->pluginData(connectPauseTs => 0);

        main::INFOLOG && $log->is_info && $log->info(
            "Track change: $prevTrackId -> $newTrackId"
        );

        my $song = $client->playingSong();
        if ($song) {
            # Reset progress bar for the new track: in stream mode,
            # songElapsedSeconds counts from the original stream start,
            # so startOffset must compensate to reset songTime to ~0.
            my $elapsed = $client->songElapsedSeconds() || 0;
            $song->startOffset(0 - $elapsed);
            $client->playPoint(undef);
            $client->pluginData(progress => 0);
        }

        # Ensure player is playing — stop→change from skip leaves squeezelite paused
        if (!$client->isPlaying && __PACKAGE__->isSpotifyConnect($client)) {
            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $playReq = Slim::Control::Request->new($client->id, ['pause', 0]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();
        }

        # Fetch metadata for the new track (D-13)
        if ($newTrackId) {
            $client->pluginData(eventTrackUri => "spotify:track:$newTrackId");
            _fetchTrackMetadata($client, $newTrackId);
        }

        return;
    }

    # -----------------------------------------------------------------
    # Stop: forward pause to LMS player (source-marked to prevent echo)
    # -----------------------------------------------------------------
    if ($cmd eq 'stop') {
        # Grace period: ignore spurious stop events during Connect session setup.
        # The binary fires Stopped between TrackChanged and Playing — this must not
        # pause the LMS player. Time-based check only (isPlaying is already true by
        # the time the stop arrives because playlist play was just issued).
        if ((Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0)) < CONNECT_START_GRACE)
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Ignoring spurious stop during Connect session setup grace period"
            );
            return;
        }

        if ($client->isPlaying && __PACKAGE__->isSpotifyConnect($client)) {
            main::INFOLOG && $log->is_info && $log->info(
                "Spotify told us to pause: " . $client->id
            );

            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
            $pauseReq->source(__PACKAGE__);
            $pauseReq->execute();
        }

        return;
    }

    main::INFOLOG && $log->is_info && $log->info("Unhandled spottyconnect command: $cmd");
}

# _fetchTrackMetadata($client, $trackId)
# Fetches track metadata from Spotify Web API and updates NowPlaying display.
# Uses API::Client->getTrack() which routes via own-token (me/* path not needed here,
# track endpoint is accessible with own or bundled token).
sub _fetchTrackMetadata {
    my ($client, $trackId) = @_;

    return unless $trackId;

    require Plugins::SpotOn::API::Client;

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';

    Plugins::SpotOn::API::Client->getTrack($accountId, $trackId, sub {
        my ($trackInfo) = @_;

        # Stale-API protection (T-05-14 / Pitfall 5): the binary's event track_id
        # has priority over the API response. If event says different track, trust event.
        my $eventUri = $client->pluginData('eventTrackUri') || '';
        if ($trackInfo && $trackInfo->{uri} && $eventUri
            && $eventUri ne $trackInfo->{uri})
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Stale API response: event=$eventUri, API=" . $trackInfo->{uri} . " — using event (T-05-14)"
            );
            $trackInfo = { uri => $eventUri };
            return;
        }

        return unless $trackInfo && $trackInfo->{name};

        my $song = $client->playingSong();
        return unless $song;

        my $title    = $trackInfo->{name};
        my $artist   = join(', ', map { $_->{name} } @{ $trackInfo->{artists} || [] });
        my $album    = ($trackInfo->{album} || {})->{name} || '';
        my $duration = ($trackInfo->{duration_ms} || 0) / 1000;
        my $cover    = _largestImage(($trackInfo->{album} || {})->{images}) || IMG_TRACK;

        # Instant display update
        Slim::Music::Info::setCurrentTitle(
            $song->streamUrl,
            "$artist - $title",
            $client
        );

        # Full metadata for Now Playing display
        $song->pluginData(info => {
            title        => $title,
            artist       => $artist,
            album        => $album,
            duration     => $duration,
            cover        => $cover,
            url          => $song->streamUrl,
            originalType => 'Ogg Vorbis (Spotify)',
            type         => 'Ogg Vorbis (Spotify)',
        });

        # Update song duration for progress bar
        if ($duration) {
            $song->duration($duration);
            $client->streamingProgressBar({
                url      => $song->streamUrl,
                duration => $duration,
            });
        }

        # Fire newmetadata notification so LMS refreshes Now Playing
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

        # Clear newTrack flag — initial metadata fetch complete
        $client->pluginData(newTrack => 0);

        main::INFOLOG && $log->is_info && $log->info(
            "Track metadata updated: $title — $artist"
        );
    });
}

# _largestImage($images_arrayref)
# Returns the URL of the largest image (by width) from a Spotify images array.
# Returns '' if the array is empty or undef.
sub _largestImage {
    my ($images) = @_;
    return '' unless ref $images eq 'ARRAY' && @{$images};
    my ($largest) = sort { ($b->{width} || 0) <=> ($a->{width} || 0) } @{$images};
    return $largest->{url} || '';
}

1;

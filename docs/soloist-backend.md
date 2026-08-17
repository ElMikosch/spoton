# Spotify Soloist backend

Spotify Soloist is the official Spotify Connect client used by this optional
Linux backend. It is not a drop-in replacement for SpotOn's bundled helper:
Soloist renders to a local PulseAudio device, so SpotOn creates an isolated null
sink per LMS player (or sync group), captures its monitor, and distributes the
PCM stream to the matching Squeezebox. The bundled helper remains responsible
for Browse/library playback.

The first integration seam lives in `Plugins/SpotOn/Soloist/`. Its protocol and
state layers deliberately have no LMS runtime dependency:

- `build_commands($action, %args)` maps SpotOn/LMS control actions to the
  documented Soloist WebSocket command messages.
- `normalize_event($event)` maps Soloist's event payloads and entity envelope to
  a stable internal shape suitable for an LMS adapter.
- `Endpoint.pm` discovers `ws.addr`, `ws.port`, and `soloist.pid`, rejects every
  non-loopback address, and produces the local WebSocket URL.
- `Transport.pm` wraps LMS's asynchronous `Slim::Networking::SimpleWS`, performs
  JSON framing, and keeps all command/event mapping behind the protocol seam.
- `Session.pm` owns connection state and reduces full and granular Soloist events
  into a current playback snapshot.
- `ProcessSpec.pm` builds a shell-free daemon argument array, fixes the
  unauthenticated WebSocket listener to `127.0.0.1:0`, validates Soloist's
  documented numeric ranges, provides a separately redacted argument array for
  logs, and passes the private Pulse socket and cookie only through the child
  process environment.
- `AudioPreflight.pm` performs a non-invasive capability check for Soloist,
  LMS WebSocket support, PulseAudio/PipeWire capture tools, and an encoder. It
  never starts a program or connects to the host's audio server.
- `PulseBridgeSpec.pm` describes the headless-container audio path as three
  shell-free process specifications: a supervised PulseAudio null sink on a
  private Unix socket, `parec` monitor capture as 44.1 kHz stereo PCM, and an
  direct low-latency PCM output plus an `ffmpeg` FLAC encoder for the stable
  fallback stream.
- `Runtime.pm` implements the supervised per-device lifecycle. It creates and
  validates private runtime/data/cache/log directories and a 256-byte Pulse
  cookie, starts PulseAudio before Soloist, waits asynchronously for their
  readiness markers, rejects non-loopback endpoints, redacts the API key from
  diagnostics, and tears the child processes down in dependency order.
- `StreamPipeline.pm` either exposes monitor PCM directly or wires it into the
  FLAC encoder with OS pipes and list-form `exec`; no shell command is
  constructed and the PCM path starts no unnecessary encoder child.
  The encoded output is nonblocking for integration with LMS's event loop, and
  disconnect cleanup terminates both children without touching the long-lived
  Soloist/Pulse runtime.
- `StreamServer.pm` exposes that pipeline through LMS's authenticated HTTP
  server only after a runtime registers an opaque 96-bit route token. It uses
  bounded nonblocking reads and socket-drain backpressure rather than buffering
  an unbounded live stream in the LMS process, supports HTTP/1.0 close-delimited
  and HTTP/1.1 chunked clients, and destroys the per-connection pipeline on EOF,
  replacement, timeout, or socket failure. Its PCM mode also provides
  timer-driven real-time pacing and
  `audio/L16;rate=44100;channels=2` response so hardware input buffers cannot
  accumulate an arbitrarily long compressed-audio backlog.
- `PlayerRuntime.pm` owns one isolated PulseAudio/Soloist process pair, local
  WebSocket session, stream token, and LMS player attachment.
- `Manager.pm` discovers LMS players and sync masters, staggers process startup,
  keeps one `PlayerRuntime` per desired Spotify device, and adapts Soloist state
  into LMS transport and metadata updates. It reads the API key only from a
  fixed owner-only cache file, validates required executables, and defers
  topology/name changes while a Spotify session is active.

When the protected API-key file exists, SpotOn enables and starts the managed
Soloist backend automatically after the LMS player list is available. Each
standalone player appears separately in Spotify; a synchronized set appears once
under its master with the localized static `(Group)` suffix. The diagnostic CLI
remains available for preflight and status inspection.

The direct WebSocket transport requires LMS 9.1 or newer, where
`Slim::Networking::SimpleWS` became part of LMS. This requirement applies only
to the Soloist backend; the rest of SpotOn keeps its existing LMS
compatibility. A `soloist ctl` subprocess fallback for older LMS versions can be
added later if real installations require it.

## Hardware probe

`Plugins/SpotOn/Soloist/Probe.pm` provides a deliberately narrow LMS CLI probe.
It never launches Soloist, never stores an API key, never changes the active
SpotOn playback backend, and accepts no caller-selected data directory. The
command is available only while SpotOn diagnostic mode is enabled.

The fixed Soloist data directory is reported by:

```text
spoton soloistprobe action:status
```

The response now also contains `soloist.preflight`. `hardwareProbeReady: 1`
means that the required executables were found for one supported prototype
path; it does not yet prove that the audio server is running or that its routing
permissions are correct. The preferred capture path is reported as either
`pulse_monitor` or `pipewire_native`, and `missing` contains stable capability
codes when the host is not ready.

The discovery-only preflight currently recognizes:

- Pulse monitor capture: `pactl` plus `parec`. A plugin-managed headless
  PulseAudio server additionally requires the `pulseaudio` executable and is
  reported as `managedPulseReady`.
- Native PipeWire capture: `pw-record` plus either `pw-dump` or `pw-cli`.
- Encoding: `ffmpeg`, with `flac` and `sox` as fallback candidates.

Start Soloist manually on the LMS host with that directory and a loopback-only,
automatically allocated WebSocket port:

```sh
soloist \
  --device-name "SpotOn Soloist Probe" \
  --api-key "$SOLOIST_API_KEY" \
  --data-dir "/path/reported/by/status" \
  --cache-dir "/path/reported/by/status/cache" \
  --ws 127.0.0.1:0
```

Treat the API key as a secret. It is supplied directly to the official binary;
SpotOn neither reads nor logs it in probe mode. Soloist currently requires the
key as a command-line option, so a future managed launcher must also document
that the live process argument can be visible to sufficiently privileged local
users through tools such as `ps` or `/proc`. `ProcessSpec.pm` guarantees that
the key is removed from the log-safe argument array, but cannot change the
official binary's input interface.

Attach the LMS session and inspect normalized state:

```text
spoton soloistprobe action:start
spoton soloistprobe action:status
```

Safe control-path checks can then use commands such as:

```text
spoton soloistprobe action:pause
spoton soloistprobe action:play
spoton soloistprobe action:volume volume:35
```

Stop detaches only the diagnostic WebSocket client; it does not terminate
Soloist:

```text
spoton soloistprobe action:stop
```

### Managed runtime diagnostics

The status response reports the fixed `apiKeyFile` path and a `players` map for
all managed runtimes:

```text
spoton soloistprobe action:managed_status
```

Before start, that file must be a regular, non-symlink file owned by the LMS
service user, with no group or other permission bits, and contain only the
Soloist API key. The key is never accepted as a CLI parameter, returned by the
status command, placed in a stream URL, or written to a SpotOn log.

```text
spoton soloistprobe action:managed_start
spoton soloistprobe action:managed_status
```

Startup is asynchronous. `managed.state: running` and entries below
`managed.players` prove that the corresponding PulseAudio, Soloist, local
WebSocket, and LMS routes are attached. Each player snapshot reports both FLAC
and raw 44.1 kHz, 16-bit little-endian stereo PCM routes. Playback normally
attaches automatically when that Soloist device becomes active; the explicit
commands remain available for diagnostics:

```text
spoton soloistprobe action:managed_player_play player_id:<player-id>
spoton soloistprobe action:managed_player_play player_id:<player-id> stream_format:pcm
spoton soloistprobe action:managed_player_stop
```

Status exposes `playerAttached`, `playerId`, and the LMS-generated
`playerStreamUrl`, plus `playerStreamFormat` for an A/B latency measurement. No
caller-supplied URL or host is accepted. Only `flac` and `pcm` are allowed. The
routes share a random token per start and are revoked before the runtime is
stopped:

```text
spoton soloistprobe action:managed_stop
```

These actions require SpotOn diagnostic mode. `managed_stop` disables the
Soloist backend persistently until `managed_start` is called again. The Unified
helper remains available for SpotOn Browse playback, but its legacy Connect
advertisement is disabled while Soloist is enabled.

## Headless Linux container path

An LMS container does not need a physical or host-provided sound device. The
prototype can run a per-LMS-user PulseAudio process containing only a null sink
and capture that sink's automatically created monitor source. Soloist writes to
the isolated sink, while SpotOn captures and encodes the same samples for LMS.

`PulseBridgeSpec.pm` deliberately keeps this path constrained:

- PulseAudio stays in the foreground so the plugin can supervise it.
- Automatic exit, runtime module loading, realtime scheduling, and a shared PID
  file are disabled.
- Clients connect only to an explicit Unix socket; no TCP PulseAudio protocol is
  loaded.
- `XDG_RUNTIME_DIR` and `XDG_CONFIG_HOME` both point into the private runtime
  tree. This is required for service accounts whose declared home directory is
  read-only or does not contain a writable `.config` parent, as is common for
  packaged LMS installations.
- The native protocol requires an explicit random authentication cookie under
  the private config tree. Server, capture client, and Soloist receive the same
  `PULSE_COOKIE` path; anonymous PulseAudio clients are not allowed.
- The managed Soloist process receives `PULSE_SERVER` and `PULSE_COOKIE` as a
  validated pair. Neither value is added to the daemon argument arrays.
- The lifecycle must create the runtime/config directories with mode `0700` and
  the cookie with mode `0600`, all owned by the LMS service user, and refuse to
  start if those conditions are not met.
- Module-interpolated socket and sink names use restrictive validation in
  addition to ordinary argv separation.

The Pulse bridge has now been exercised successfully in a Debian 13 LXC under
the packaged LMS service account. A real Soloist 1.3.7 Connect session produced
continuous monitor PCM which encoded to a non-silent FLAC with matching
duration. The per-player manager and streaming endpoint now supervise this path
automatically on configured installations.

## Implemented architecture

1. Run one Soloist process per eligible LMS sync master with its WebSocket bound
   to loopback only.
2. Connect the asynchronous local WebSocket/session and validated process
   specification to an API-key-gated daemon lifecycle.
3. Route Soloist audio into an isolated PipeWire/PulseAudio sink and capture the
   monitor stream.
4. Encode the captured PCM as FLAC and expose it through LMS's existing
   streaming path.
5. Adapt normalized events to SpotOn's Connect session and metadata lifecycle.
6. Keep the Spotify Web API browse/library UI and its normal LMS-managed
   playback path available independently of Connect.

## Operational constraints

- Soloist currently supports Linux on its published architectures and emits
  audio only through PipeWire or PulseAudio.
- Its local WebSocket API has no authentication or TLS, so SpotOn must bind it
  to loopback and must not proxy it to the LAN.
- Soloist builds expire after 90 days and cannot simply be bundled with SpotOn;
  installation and updates need a user-owned API key and current host binary.
- Buffering, volume, seek/skip, sync-group behavior, and clean teardown remain
  covered by regression tests and real Squeezebox hardware checks.

Protocol reference:
[Spotify Soloist WebSocket API](https://developer.spotify.com/documentation/soloist/reference/websocket-api).
Runtime references:
[Spotify Soloist downloads](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates),
[PulseAudio null sink](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/User/Modules/),
and [Debian `parec`](https://manpages.debian.org/trixie/pulseaudio-utils/parec.1.en.html).

# Experimental Spotify Soloist backend

SpotOn currently uses its bundled librespot helper for both Spotify Connect and
LMS-managed playback. Spotify Soloist is an official Spotify Connect client,
but it is not a drop-in replacement for that helper: Soloist renders to a local
PipeWire or PulseAudio device, while SpotOn's helper exposes an HTTP audio stream
that LMS can buffer and distribute to Squeezebox players.

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
  documented numeric ranges, and provides a separately redacted argument array
  for logs.
- `AudioPreflight.pm` performs a non-invasive capability check for Soloist,
  LMS WebSocket support, PulseAudio/PipeWire capture tools, and an encoder. It
  never starts a program or connects to the host's audio server.

SpotOn registers the diagnostics-only probe but does not start a Soloist
connection automatically. Existing Connect and browse playback therefore remain
unchanged while the Soloist path is developed and tested incrementally.

The direct WebSocket transport requires LMS 9.1 or newer, where
`Slim::Networking::SimpleWS` became part of LMS. This requirement applies only
to the experimental Soloist backend; the rest of SpotOn keeps its existing LMS
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

- Pulse monitor capture: `pactl` plus `parec`.
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

## Planned architecture

1. Run one Soloist process per eligible LMS sync master with its WebSocket bound
   to loopback only.
2. Connect the completed asynchronous local WebSocket/session and validated
   process specification to an explicit, opt-in daemon lifecycle.
3. Route Soloist audio into an isolated PipeWire/PulseAudio sink and capture the
   monitor stream.
4. Encode and expose that captured audio through LMS's existing streaming path.
5. Adapt normalized events to SpotOn's Connect session and metadata lifecycle.
6. Keep the Spotify Web API browse/library UI and its normal LMS-managed
   playback path available independently of Connect.

## Constraints to prove before enabling the backend

- Soloist currently supports Linux on its published architectures and emits
  audio only through PipeWire or PulseAudio.
- Its local WebSocket API has no authentication or TLS, so SpotOn must bind it
  to loopback and must not proxy it to the LAN.
- Soloist builds expire after 90 days and cannot simply be bundled with SpotOn;
  installation and updates need a user-owned API key and explicit lifecycle UI.
- The capture relay must preserve correct volume behavior, startup buffering,
  seek/skip transitions, sync-group behavior, and clean teardown.
- The official backend must remain opt-in until those behaviors pass on real LMS
  and Squeezebox hardware.

Protocol reference:
[Spotify Soloist WebSocket API](https://developer.spotify.com/documentation/soloist/reference/websocket-api).

# Experimental Spotify Soloist backend

SpotOn currently uses its bundled librespot helper for both Spotify Connect and
LMS-managed playback. Spotify Soloist is an official Spotify Connect client,
but it is not a drop-in replacement for that helper: Soloist renders to a local
PipeWire or PulseAudio device, while SpotOn's helper exposes an HTTP audio stream
that LMS can buffer and distribute to Squeezebox players.

The first integration seam lives in
`Plugins/SpotOn/Soloist/Protocol.pm`. It deliberately has no LMS or WebSocket
dependency and provides two operations:

- `build_commands($action, %args)` maps SpotOn/LMS control actions to the
  documented Soloist WebSocket command messages.
- `normalize_event($event)` maps Soloist's event payloads and entity envelope to
  a stable internal shape suitable for an LMS adapter.

Nothing loads this module in production yet. Existing Connect and browse
playback therefore remain unchanged while the Soloist path is developed and
tested incrementally.

## Planned architecture

1. Run one Soloist process per eligible LMS sync master with its WebSocket bound
   to loopback only.
2. Add an asynchronous local WebSocket transport and feed decoded events through
   the protocol boundary.
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

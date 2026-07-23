---
name: spoton-uat
description: "Autonomous end-to-end UAT for SpotOn — tests Spotify Connect and Browse playback across OGG/PCM modes with real audio verification via squeezelite debug logs. Use when testing SpotOn changes, verifying a release, or validating playback after code changes."
argument-hint: "[connect|browse|all] [--quick] [--no-connect] [--no-browse] [--record N] [--teardown]"
allowed-tools:
  - Read
  - Bash
  - AskUserQuestion
  - ToolSearch
---

<objective>
Run autonomous end-to-end playback tests for SpotOn across all four playback paths:
1. **Connect OGG** (Passthrough) — Spotify Desktop (CDP) → librespot → OGG pipe → squeezelite
2. **Connect PCM** — Spotify Desktop (CDP) → librespot → PCM decode → squeezelite
3. **Browse OGG** (Passthrough) — LMS JSON-RPC → SpotOn → OGG pipe → squeezelite
4. **Browse PCM** — LMS JSON-RPC → SpotOn → PCM decode → squeezelite

For each mode, run a configurable subset of test cases (Play, Pause, Resume, Skip, Seek, Rapid Skip, Auto-advance). Verify real audio delivery via:
- **PipeWire null sink** — squeezelite outputs to a virtual sink (no real speakers)
- **pw-record + sox** — capture and analyze audio from the null sink
- **squeezelite debug logs** — decode type, stream connections, errors

Produce a summary table at the end with Pass/Fail/Skip per test.
</objective>

<environment>
## Infrastructure

LMS JSON-RPC:        http://127.0.0.1:9000/jsonrpc.js (local LMS on desktop)
LMS Player:          "claude" — MAC discovered dynamically (never hardcode)
LMS logs:            sudo cat /var/log/squeezeboxserver/server.log
LMS restart:         sudo systemctl restart lyrionmusicserver
Status endpoint:     http://127.0.0.1:9000/plugins/SpotOn/status/data (JSON)

Spotify Desktop:     localhost:9222 (CDP, --remote-debugging-port=9222)
Spotify CDP tool:    /home/sti/spoton-private/tools/spotify-cdp.js
CDP commands:        status | play | pause | toggle | next | prev | devices | connect <device> | disconnect | start | stop

squeezelite binary:  /usr/bin/squeezelite-pulseaudio
squeezelite service: systemctl --user {start|stop} squeezelite.service
squeezelite debug:   /usr/bin/squeezelite-pulseaudio -n claude -s 127.0.0.1 -o test_sink -d all=info -d decode=debug -d stream=debug
Debug log:           /tmp/squeezelite-uat.log

PipeWire null sink:  test_sink (created at setup, no real audio output)
Audio capture:       pw-record --target=test_sink <file.wav>
Audio analysis:      sox <file.wav> -n stat (RMS, duration, silence detection)
</environment>

<flags>
--quick        Play + Skip only (skip Pause/Resume/Seek/RapidSkip/AutoAdvance)
--no-connect   Skip Connect modes
--no-browse    Skip Browse modes
--teardown     Cleanup only: stop debug squeezelite, restore service, disconnect Spotify
--record N     Seconds to record per audio capture (default: 8)
</flags>

<process>

## Phase 1: Scope

Parse `$ARGUMENTS` for scope. If no arguments, ask via AskUserQuestion.

**Argument parsing:**
- `connect` → only Connect modes (OGG + PCM)
- `browse` → only Browse modes (OGG + PCM)
- `all` or no scope → full matrix
- `--quick` → Play + Skip only per mode
- `--no-connect` / `--no-browse` → exclude modes
- `--teardown` → jump directly to Phase 4

**If asking:**

Question 1 (multiSelect): "Welche Playback-Modi testen?"
- Connect OGG (Passthrough)
- Connect PCM
- Browse OGG (Passthrough)
- Browse PCM

Question 2 (multiSelect): "Welche Tests pro Modus?"
- Play Song
- Pause + Resume
- Skip (next track)
- Seek (jump within track)
- Rapid Skip (3+ skips in <3s)
- Auto-advance (wait for song end)

Default if no answer: All modes, all tests except Auto-advance.

## Phase 2: Setup

### 2.1 Preflight — verify all components

```bash
# Spotify CDP
curl -s http://localhost:9222/json > /dev/null 2>&1 && echo "spotify-cdp: OK" || { echo "FAIL: Start Spotify with: /usr/bin/spotify --remote-debugging-port=9222 --show-console &"; exit 1; }

# LMS
curl -s -X POST http://127.0.0.1:9000/jsonrpc.js -H "Content-Type: application/json" \
  -d '{"id":1,"method":"slim.request","params":["",["serverstatus",0,1]]}' > /dev/null 2>&1 && echo "lms: OK" || { echo "FAIL: LMS not running"; exit 1; }

# sox + pw-record
which sox > /dev/null 2>&1 && echo "sox: OK" || echo "WARN: sox missing — audio analysis disabled"
which pw-record > /dev/null 2>&1 && echo "pw-record: OK" || echo "WARN: pw-record missing — audio capture disabled"

# CDP tool
test -f /home/sti/spoton-private/tools/spotify-cdp.js && echo "cdp-tool: OK" || { echo "FAIL: spotify-cdp.js not found"; exit 1; }
```

### 2.2 Create PipeWire null sink

```bash
pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=test_sink media.class=Audio/Sink object.linger=true audio.position=[FL,FR] node.description="UAT Test Sink" }' 2>/dev/null || true
sleep 1
pw-cli ls Node 2>/dev/null | grep -q test_sink && echo "null-sink: OK" || echo "WARN: null sink creation failed"
```

### 2.3 Start squeezelite debug on null sink

```bash
# Stop normal service
systemctl --user stop squeezelite.service 2>/dev/null
sleep 1

# Kill any existing debug instance
pkill -f 'squeezelite.*claude' 2>/dev/null; sleep 1

# Start debug instance on null sink
/usr/bin/squeezelite-pulseaudio -n claude -s 127.0.0.1 -o test_sink \
  -d all=info -d decode=debug -d stream=debug \
  > /tmp/squeezelite-uat.log 2>&1 &
SQPID=$!
echo $SQPID > /tmp/squeezelite-uat.pid
sleep 3

pgrep -a squeezelite | grep -q claude && echo "squeezelite-debug: OK (PID $SQPID)" || { echo "FAIL: squeezelite not running"; exit 1; }
```

### 2.4 Discover player MAC

```bash
PLAYER_MAC=$(curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["players","0","10"]]}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); players=[p for p in d['result'].get('players_loop',[]) if p['name']=='claude']; print(players[0]['playerid'] if players else 'NOT_FOUND')")
echo "Player MAC: $PLAYER_MAC"
```

If NOT_FOUND after 10s, squeezelite didn't register with LMS. Check process and retry.

### 2.5 Save current prefs (for restore)

```bash
ORIG_STREAM_FORMAT=$(curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_MAC\",[\"playerpref\",\"plugin.spoton:streamFormat\",\"?\"]]}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['_p2'])")
ORIG_CONNECT_OGG=$(curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_MAC\",[\"playerpref\",\"plugin.spoton:connectOggOverride\",\"?\"]]}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['_p2'])")
echo "Saved prefs: streamFormat=$ORIG_STREAM_FORMAT, connectOggOverride=$ORIG_CONNECT_OGG"
```

### 2.6 Baseline status capture

```bash
STATUS_BASELINE=$(curl -s http://127.0.0.1:9000/plugins/SpotOn/status/data)
BASELINE_ERROR_COUNT=$(echo "$STATUS_BASELINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('errors',[])))")
BASELINE_DAEMON_COUNT=$(echo "$STATUS_BASELINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('daemons',[])))")
echo "Baseline: $BASELINE_DAEMON_COUNT daemon(s), $BASELINE_ERROR_COUNT error(s)"
```

## Phase 3: Test Execution

### Test Tracks

- Track 1: `4uLU6hMCjMI75M1A2tKUQC` (Rick Astley - Never Gonna Give You Up, ~3:33)
- Track 2: `3n3Ppam7vgaVa1iaRUc9Lp` (Mr. Brightside - The Killers, ~3:42)
- Track 3: `7GhIk7Il098yCjg4BQjzvb` (Daft Punk - Around The World, ~7:09)

### Mode Switching Order

Test in this order to minimize daemon restarts:
1. Browse PCM (safest baseline)
2. Browse OGG
3. Connect PCM
4. Connect OGG

### Pref Change + Daemon Restart

After setting format prefs via JSON-RPC, trigger `scheduleInit()`:

```bash
MAC_ENC=$(echo "$PLAYER_MAC" | sed 's/:/%3A/g')
curl -s -X POST "http://127.0.0.1:9000/plugins/SpotOn/settings/player.html" \
  -d "saveSettings=1&player=${MAC_ENC}&playerid=${MAC_ENC}&pref_streamFormat=VALUE&pref_connectOggOverride=VALUE&pref_enableSpotifyConnect=1&pref_enableDiscovery=1&pref_enableAutoplay=1" \
  -o /dev/null
sleep 5
```

### Audio Capture + Analysis Helper

Run this after each test to verify real audio delivery:

```bash
DURATION=${RECORD_SECONDS:-8}
CAPTURE_FILE="/tmp/uat-capture-$(date +%s).wav"

# Record from null sink
pw-record --target=test_sink "$CAPTURE_FILE" &
REC_PID=$!
sleep $DURATION
kill $REC_PID 2>/dev/null; wait $REC_PID 2>/dev/null

# Analyze
if [ -f "$CAPTURE_FILE" ] && [ -s "$CAPTURE_FILE" ]; then
  AUDIO_STATS=$(sox "$CAPTURE_FILE" -n stat 2>&1)
  RMS=$(echo "$AUDIO_STATS" | grep "RMS.*amplitude" | head -1 | awk '{print $NF}')
  DURATION_ACTUAL=$(echo "$AUDIO_STATS" | grep "Length" | awk '{print $NF}')
  echo "Audio: RMS=$RMS, Duration=${DURATION_ACTUAL}s"
  if python3 -c "exit(0 if float('$RMS') > 0.001 else 1)" 2>/dev/null; then
    echo "AUDIO_OK: Real audio detected (RMS=$RMS)"
  else
    echo "AUDIO_SILENT: No audio (RMS=$RMS) — check pipeline"
  fi
else
  echo "AUDIO_FAIL: Capture file empty or missing"
fi
rm -f "$CAPTURE_FILE"
```

Pass criteria:
- File > 0 bytes
- RMS > 0.001 (audio present, not silence)
- Duration within 2s of requested

### Status Health Check (after each test)

```bash
STATUS_NOW=$(curl -s http://127.0.0.1:9000/plugins/SpotOn/status/data)
python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
baseline_errors = $BASELINE_ERROR_COUNT
issues = []
for d in data.get('daemons', []):
    if not d.get('alive'):
        issues.append(f'DAEMON DEAD: {d[\"name\"]} (mac={d[\"mac\"]})')
current_errors = data.get('errors', [])
new_errors = len(current_errors) - baseline_errors
if new_errors > 0:
    issues.append(f'NEW ERRORS: {new_errors} since baseline')
api = data.get('api', {})
if api.get('consecutive_429s', 0) > 0:
    issues.append(f'RATE LIMITED: {api[\"consecutive_429s\"]} consecutive 429s')
if issues:
    print('⚠ STATUS:', '; '.join(issues))
else:
    print('Status: healthy')
" <<< "$STATUS_NOW"
```

If DAEMON DEAD: stop current mode, report. If RATE LIMITED: pause 30s.

### 3.1 Browse Mode Tests

**Setup per mode:**
```bash
# Set format pref (ogg or pcm)
curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_MAC\",[\"playerpref\",\"plugin.spoton:streamFormat\",\"FORMAT\"]]}"
# Trigger daemon restart via settings save
# (see "Pref Change + Daemon Restart" above)
# Power on player
curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_MAC\",[\"power\",\"1\"]]}"
```

**Test: Play Song**
1. Clear squeezelite log: `echo "" > /tmp/squeezelite-uat.log`
2. `playlist play spoton://track:4uLU6hMCjMI75M1A2tKUQC`
3. Wait 5s
4. Check LMS status: `mode` = `play`, `time` > 0
5. Check squeezelite log: `decode_ogg` (OGG) or `decode_pcm` (PCM), `stream_sock` connection
6. Run audio capture + analysis (8s)
7. PASS if mode=play AND time>0 AND AUDIO_OK AND correct decode type in log

**Test: Pause + Resume**
1. Prerequisite: song playing, time > 2s
2. `pause 1`, wait 2s, check `mode` = `pause`
3. Record time as T1
4. `pause 0`, wait 3s, check `mode` = `play`, `time` > T1
5. Run audio capture (5s) — verify audio resumes
6. PASS if pause stops and resume advances

**Test: Skip**
1. Prerequisite: 2+ tracks in playlist (add Track 2 first)
2. Record current track title
3. `playlist index +1`, wait 5s
4. Check track title changed
5. Check squeezelite log: new stream connection
6. Run audio capture — verify audio on new track
7. PASS if track changed AND AUDIO_OK

**Test: Seek**
1. Prerequisite: song playing
2. `time 30` (seek to 30s), wait 3s
3. Check `time` ≈ 30s (±5s tolerance)
4. Run audio capture — verify audio continues
5. PASS if time ≈ 30s AND AUDIO_OK

**Test: Rapid Skip**
1. Prerequisite: 4+ tracks in playlist
2. Send 3 skip commands < 1s apart
3. Wait 8s (audio-key throttle recovery)
4. Check `mode` = `play`, audio flowing
5. Run audio capture
6. PASS if playing after rapid skips without stalling

**Test: Auto-advance**
1. Prerequisite: 2+ tracks in playlist
2. Get duration, seek to `duration - 10`
3. Wait 15s
4. Check track title changed, `mode` = `play`
5. PASS if track changed automatically

### 3.2 Connect Mode Tests

Connect uses Spotify Desktop via CDP instead of LMS JSON-RPC for transport control.

**Setup per mode:**
```bash
# Set connect override pref (ogg or pcm)
curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_MAC\",[\"playerpref\",\"plugin.spoton:connectOggOverride\",\"FORMAT\"]]}"
# Trigger daemon restart
# (see "Pref Change + Daemon Restart")
```

**Connect to player:**
```bash
# Check claude is visible as Connect device
node /home/sti/spoton-private/tools/spotify-cdp.js devices
# Transfer playback to claude
node /home/sti/spoton-private/tools/spotify-cdp.js connect claude
sleep 3
# Start playback
node /home/sti/spoton-private/tools/spotify-cdp.js play
sleep 5
# Verify
node /home/sti/spoton-private/tools/spotify-cdp.js status
```

**Test: Play**
1. Clear squeezelite log
2. `cdp play` (if not already), wait 5s
3. Check `cdp status`: playing, position advancing
4. Check LMS status: shows Spotify track metadata
5. Check squeezelite log: correct decode type
6. Run audio capture
7. PASS if all three confirm playback

**Test: Pause + Resume**
1. `cdp pause`, wait 2s
2. Check `cdp status`: paused
3. Check LMS status: `mode` = `pause`
4. `cdp play`, wait 3s
5. Check both: playing, position advancing
6. Run audio capture
7. PASS if pause/resume works end-to-end

**Test: Skip**
1. Record current track from `cdp status`
2. `cdp next`, wait 5s
3. Check `cdp status`: different track
4. Check LMS status: track changed
5. Run audio capture
6. PASS if track changed AND AUDIO_OK

**Test: Seek**
Connect seek via CDP is not available (no seek command in the tool). Use LMS JSON-RPC `time` command which proxies to Spotify in Connect mode:
1. `["time","30"]` via LMS JSON-RPC, wait 3s
2. Check LMS status: `time` ≈ 30s
3. PASS if time ≈ 30s. SKIP if seek is not proxied in Connect mode.

**Test: Rapid Skip**
1. Send 3 `cdp next` commands < 1s apart
2. Wait 8s
3. Check `cdp status` + LMS status: playing
4. Run audio capture
5. PASS if recovers and plays

**Test: Auto-advance**
Auto-advance in Connect is handled by Spotify/librespot, not LMS. Cannot seek-to-end via CDP. SKIP this test in Connect mode unless `--quick` is off and user explicitly opted in — in that case, wait for a full short track to end naturally.

### 3.3 Verification Patterns

**squeezelite log patterns:**

| Pattern | Meaning |
|---------|---------|
| `stream_sock` or `connect:` | New stream connection |
| `decode_ogg` | OGG Vorbis decoder active (confirms passthrough) |
| `decode_pcm` | PCM decoder active |
| `output_` + buffer values | Audio being sent to output |
| `STMd` | Decoder ready |
| `STMs` | Track started |
| `vorbis_decode:160 open_callbacks error: -132` | Decode error (transient on track switch = OK, persistent = FAIL) |

**Read and clear log between tests:**
```bash
tail -50 /tmp/squeezelite-uat.log
echo "" > /tmp/squeezelite-uat.log
```

**LMS status check:**
```bash
curl -s -X POST http://127.0.0.1:9000/jsonrpc.js \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_MAC\",[\"status\",\"-\",\"1\",\"tags:adlNJKr\"]]}" \
  | python3 -m json.tool
```

Key fields: `mode` (play/pause/stop), `time` (position), `duration`, `remoteMeta.title`, `remoteMeta.artist`, `can_seek`, `player_connected`.

## Phase 4: Teardown

ALWAYS run after testing — restores normal squeezelite service:

```bash
# Transfer Spotify back to desktop
node /home/sti/spoton-private/tools/spotify-cdp.js disconnect 2>/dev/null || true

# Kill debug squeezelite
kill $(cat /tmp/squeezelite-uat.pid 2>/dev/null) 2>/dev/null || pkill -f 'squeezelite.*test_sink' 2>/dev/null || pkill -f 'squeezelite.*claude' 2>/dev/null
sleep 1

# Restore normal squeezelite service
systemctl --user start squeezelite.service
sleep 2
pgrep -a squeezelite && echo "SQUEEZELITE_SERVICE_RESTORED" || echo "WARN: squeezelite service not started"

# Restore original prefs
MAC_ENC=$(echo "$PLAYER_MAC" | sed 's/:/%3A/g')
curl -s -X POST "http://127.0.0.1:9000/plugins/SpotOn/settings/player.html" \
  -d "saveSettings=1&player=${MAC_ENC}&playerid=${MAC_ENC}&pref_streamFormat=${ORIG_STREAM_FORMAT}&pref_connectOggOverride=${ORIG_CONNECT_OGG}&pref_enableSpotifyConnect=1&pref_enableDiscovery=1&pref_enableAutoplay=1" \
  -o /dev/null
sleep 3
echo "Prefs restored: streamFormat=$ORIG_STREAM_FORMAT, connectOggOverride=$ORIG_CONNECT_OGG"

# Cleanup
rm -f /tmp/squeezelite-uat.log /tmp/squeezelite-uat.pid /tmp/uat-capture-*.wav
echo "Teardown complete"
```

## Phase 5: Report

Present results as a Markdown table:

```
## SpotOn UAT Results — YYYY-MM-DD

| Test | Connect OGG | Connect PCM | Browse OGG | Browse PCM |
|------|:-----------:|:-----------:|:----------:|:----------:|
| Play | ✓ | ✓ | ✓ | ✓ |
| Pause/Resume | ✓ | ✓ | ✓ | ✓ |
| Skip | ✓ | FAIL | ✓ | ✓ |
| Seek | SKIP | SKIP | ✓ | ✓ |
| Rapid Skip | ✓ | ✓ | ✓ | ✓ |
| Auto-advance | SKIP | SKIP | ✓ | ✓ |

**Audio verification:** pw-record → sox analysis (null sink, no real audio)

### Failures
(Detail any FAIL with expected vs actual + log snippets)

### Status Anomalies
(Any daemon crashes, new errors, rate limiting during test)

### Notes
(Observations, warnings)
```

For FAIL results include:
- Expected vs actual behavior
- squeezelite log snippet (last 10 lines)
- LMS server log snippet if relevant
- Audio analysis output (RMS, duration)
- LMS status JSON at failure time

</process>

<error_handling>
- CDP not reachable: "Start Spotify: /usr/bin/spotify --remote-debugging-port=9222 --show-console &"
- Player not found: squeezelite not registered. Check process, restart, retry.
- No audio (RMS < 0.001): Check pipeline — is Spotify playing? Is daemon alive? Is stream connected?
- Rapid skip stalls: Known Spotify audio-key throttle (~2min recovery). Wait and retry. PASS if recovers.
- vorbis_decode error -132: Normal on track switch, only FAIL if persistent during playback.
- Null sink missing: pw-cli create failed. Check PipeWire is running: `systemctl --user status pipewire`
- Daemon restart loop: After pref change, daemon may crash-loop. Check LMS log, report as FAIL for that mode.
</error_handling>

<tips>
## Timing

- After `playlist play`: wait **5s** (track fetch + stream start)
- After pref change + settings save: wait **5s** (daemon restart)
- After `cdp connect`: wait **3s** (device transfer)
- After seek: wait **3s** (stream reposition)
- After rapid skip: wait **8s** (audio-key throttle recovery)
- For auto-advance: seek to end-10s, wait **15s**
- Audio capture: default 8s, configurable via `--record N`

## Common Issues

- **"No devices found" in CDP**: daemon discovery disabled or daemon crashed. Check SpotOn status page.
- **Rapid skip stalls**: Spotify audio-key throttle (~2min recovery). This is a PASS if it recovers.
- **Browse play returns empty**: Token expired or API rate limited. Check status endpoint.
- **Connect mode no metadata in LMS**: Metadata fetch may be 429-backed-off. Check error count.
</tips>

# Troubleshooting

Common issues and how to resolve them. Before opening an issue, please check if your problem is covered here.

## Collecting Diagnostic Data

SpotOn v1.5.1+ has a built-in diagnostic system that collects system info and daemon logs into a single downloadable file.

1. Go to **SpotOn Settings** (Server Settings > SpotOn)
2. Scroll to **Diagnostics** and enable the checkbox
3. Click **Save**
4. Reproduce the issue
5. Return to SpotOn Settings and click **Download Diagnostic Report**
6. Attach the `.txt` file to your GitHub issue

The bundle includes: LMS version, OS, Perl version, SpotOn version, player list, active settings, and all Connect daemon logs.

## Known Issues

### Daemon doesn't start (Docker)

**Symptoms:** Log shows `SpotOn daemon did not announce HTTP stream port (timeout) - aborting` repeatedly, followed by `crashed 3 times within less than 5 minutes - disabling discovery for 30 min`.

**Cause:** Docker networking can prevent the daemon from reaching LMS or announcing itself via mDNS.

**Solutions:**
- Update to SpotOn v1.5.1+ (fixes hardcoded `127.0.0.1` and mDNS routing for containers)
- Use `--network host` in your Docker run command, or ensure the container can reach the LMS host IP
- Verify the SpotOn binary runs: exec into the container and run `/path/to/spoton --check` — you should see `ok spoton v1.1.1`

If the issue persists, collect a diagnostic bundle and include your Docker setup (docker-compose.yml or run command) in the issue.

### Player not visible in Spotify app (IPv6 disabled)

**Symptoms:** LMS player does not appear in the Spotify app's device list at all. The `spoton/__DISCOVER__` folder exists but is empty. Daemon log may show `Discovery failed: Unknown error { Address family not supported by protocol (os error 97) }`.

**Cause:** IPv6 is disabled on the system (common on piCorePlayer and some Raspberry Pi setups via `ipv6.disable=1` in `/boot/firmware/cmdline.txt`). SpotOn's mDNS library (libmdns) requires IPv6 sockets — when the IPv6 address family is unavailable, discovery fails silently.

**Solution:**
1. SSH into your Pi
2. Edit `/boot/firmware/cmdline.txt` (or `/boot/cmdline.txt` on older setups)
3. Change `ipv6.disable=1` to `ipv6.disable=0`
4. Reboot

Your player should appear in the Spotify app immediately after reboot.

**Credit:** Discovered by Rasputin_GY on the Lyrion forum.

### Slow track change on hardware players (Squeezebox Radio/Touch)

**Symptoms:** When changing tracks via Spotify Connect, the new track title appears in the UI but the old audio continues playing for 10-20 seconds.

**Likely cause:** The hardware player has a large audio buffer. When Connect changes tracks, new audio starts flowing immediately but the player continues draining its buffer.

**Things to try:**
- Check your streaming format: **SpotOn Player Settings > Streaming Format**. Hardware players cannot decode OGG natively — if set to "Auto" or "OGG", LMS transcodes on the fly which adds latency. Try **"PCM"** or **"FLAC"**.
- Compare with a squeezelite or piCorePlayer — software players typically don't have this buffer delay.
- Collect a diagnostic bundle during the slow track change and open an issue — the timing data helps us investigate.

### Spotify app shows "Connecting" forever during ZeroConf auth

**Symptoms:** When you tap your LMS player name in the Spotify app to authorize SpotOn, the app shows a blinking speaker icon and "Connecting..." that never resolves. It looks like the connection failed, but the authorization actually succeeded.

**Cause:** This is expected behavior with ZeroConf authentication. The Spotify app expects a Spotify Connect playback session, but SpotOn only uses the ZeroConf handshake to receive credentials — it doesn't start a playback session at that point. The app never gets a "connected" confirmation and eventually times out.

**What to do:**
1. After tapping your player in the Spotify app, wait a few seconds
2. If you have the SpotOn Settings page open in your browser, it will detect the successful authentication automatically and reload — your Spotify username should appear under **Account Settings**
3. If it doesn't update, refresh the page manually
4. If the username is there, authentication was successful. You can now browse Spotify and use Connect normally.

**Known limitation:** This cannot be fixed without architectural changes. Discovery runs under the LMS server name (one instance for all players), while Connect daemons run under individual player names. Starting a Connect session during discovery would require matching these identities, which is not feasible with the current design. The Spotify app will always show "Connecting..." during ZeroConf auth — but the credentials are received successfully in the background.

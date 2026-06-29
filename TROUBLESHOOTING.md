# Troubleshooting

Common issues and how to resolve them. Always update to the [latest release](https://github.com/stiefenm/spoton/releases/latest) before troubleshooting — many issues are fixed in newer versions.

## Collecting Diagnostic Data

SpotOn has a built-in diagnostic system that collects system info, daemon logs, and LMS server log entries into a single downloadable file.

1. Go to **SpotOn Settings** (Server Settings > SpotOn)
2. Scroll to **Diagnostics** and enable the checkbox
3. Click **Save**
4. Reproduce the issue
5. Return to SpotOn Settings and click **Download Diagnostic Report**
6. Attach the `.txt` file to your GitHub issue

The bundle includes: LMS version, OS, Perl version, SpotOn version, player list, active settings, Connect and unified daemon logs, browse error log, and SpotOn-related entries from the LMS server log.

## Known Issues

### Daemon doesn't start (Docker)

**Symptoms:** Log shows `SpotOn daemon did not announce HTTP stream port (timeout) - aborting` repeatedly, followed by `crashed 3 times within less than 5 minutes - disabling discovery for 30 min`.

**Cause:** Docker networking can prevent the daemon from reaching LMS or announcing itself via mDNS.

**Solutions:**
- Make sure you are running the latest SpotOn version
- Use `--network host` in your Docker run command, or ensure the container can reach the LMS host IP
- Verify the SpotOn binary runs: exec into the container and run `/path/to/spoton --check` — you should see `ok spoton vX.Y.Z`

If the issue persists, collect a diagnostic bundle and include your Docker setup (docker-compose.yml or run command) in the issue.

### OGG playback issues on some players

**Symptoms:** Tracks skip early, stutter, or fail to play when streaming format is set to "OGG" or "Auto".

**Cause:** Spotify's OGG Vorbis stream contains non-standard metadata headers that some players handle poorly. Hardware players (Squeezebox Radio, Touch) cannot decode OGG natively — LMS must transcode on the fly, which can add latency and cause buffer issues.

**Solutions:**
- Go to **SpotOn Player Settings** and change **Streaming Format** to **"PCM"** or **"FLAC"** — these are universally compatible
- If you experience slow track changes on hardware players (10-20s delay), this is typically caused by the player's audio buffer draining. PCM/FLAC reduces this significantly
- Collect a diagnostic bundle during the issue and open a ticket

### Spotify app shows "Connecting" forever during ZeroConf auth

**Symptoms:** When you tap your LMS player name in the Spotify app to authorize SpotOn, the app shows a blinking speaker icon and "Connecting..." that never resolves. It looks like the connection failed, but the authorization actually succeeded.

**Cause:** This is expected behavior with ZeroConf authentication. The Spotify app expects a Spotify Connect playback session, but SpotOn only uses the ZeroConf handshake to receive credentials — it doesn't start a playback session at that point. The app never gets a "connected" confirmation and eventually times out.

**What to do:**
1. After tapping your player in the Spotify app, wait a few seconds
2. If you have the SpotOn Settings page open in your browser, it will detect the successful authentication automatically and reload — your Spotify username should appear under **Account Settings**
3. If it doesn't update, refresh the page manually
4. If the username is there, authentication was successful. You can now browse Spotify and use Connect normally.

### Search or Playlists return "No results" with custom Client ID

**Symptoms:** SpotOn search returns "Keine Ergebnisse" / "No results" for any query. Playlist contents may also show as empty. Removing the custom client ID from SpotOn settings fixes the issue.

**Cause:** Since February 2026, Spotify requires the **owner of a Developer App to have an active Premium subscription**. If your Developer App is registered under a Free account, API requests through that client ID will silently fail — returning empty results instead of an error. See [Spotify's February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide).

**Solutions:**
- **Remove the custom client ID** from SpotOn settings. SpotOn's built-in authentication already provides full API access (search, library, playlists) via a bundled token — no Developer App needed. This is the recommended setup.
- If you want to keep your custom client ID: verify that the Spotify account owning the app has Premium, and that the app is properly configured on the [Developer Dashboard](https://developer.spotify.com/dashboard).

**Background:** SpotOn uses three token sources from a single ZeroConf authentication: a **Keymaster token** for Connect, a **bundled client ID** for API access out of the box, and an optional **custom client ID** for users with Extended Quota. The bundled token covers all API functionality — a custom client ID is only needed if you have specific quota requirements from Spotify.

### Tracks skip or fail with "404" in logs (CDN errors)

**Symptoms:** Tracks skip to the next song after a few seconds, or playback fails entirely. The LMS log shows `Browse daemon 404` or `attempts exhausted, skipping to next track`.

**Cause:** Spotify occasionally returns bad CDN endpoints that respond with HTTP 404. This is a server-side issue on Spotify's end.

**Solutions:**
- **Update to v2.1.6 or later** — includes an upgraded librespot with CDN fallback (automatically tries the next CDN URL on 404) plus SpotOn's own 404 retry layer (3 attempts with 2s delay)
- If errors persist after updating, you can block specific bad CDN hosts via `/etc/hosts` — see the [forum thread](https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton) for known problematic hosts

## mDNS Discovery Not Working (Docker, VLANs, Remote LMS)

SpotOn uses mDNS (ZeroConf) for initial authentication: the Spotify app on your phone discovers the SpotOn daemon on your LMS server via local network broadcast. This requires both devices to be on the **same network segment**.

This won't work if:
- LMS runs in a **Docker container** (isolated network namespace)
- LMS and your phone are on **different VLANs/subnets**
- A **firewall** blocks mDNS (UDP port 5353)

Note: this only affects the initial setup. Once credentials are stored, Spotify Connect works through any network (it uses Spotify's cloud servers, not mDNS).

### Solution: Manual Credential Transfer

You can run the discovery step on any machine that IS on the same network as your phone, then transfer the credentials to your LMS server.

**Step 1:** Download the SpotOn binary for your platform from the [latest release](https://github.com/stiefenm/spoton/releases/latest).

**Step 2:** Run discovery on a machine on the same network as your phone:

```
spoton --discover-once --name "SpotOn Setup" -c /tmp/spoton-auth
```

**Step 3:** Open the Spotify app on your phone, tap the device icon, and select "SpotOn Setup" from the list.

**Step 4:** Copy the `credentials.json` from `/tmp/spoton-auth/` into SpotOn's `__DISCOVER__` directory on your LMS server. LMS must be running (do NOT restart between this step and the next):

```bash
# Linux (typical path — adjust if your cache directory differs)
sudo -u squeezeboxserver mkdir -p /var/lib/squeezeboxserver/cache/spoton/__DISCOVER__
sudo cp /tmp/spoton-auth/credentials.json /var/lib/squeezeboxserver/cache/spoton/__DISCOVER__/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/cache/spoton/__DISCOVER__/
```

On Windows, the cache directory is typically `C:\ProgramData\Lyrion\Cache\spoton\`.

**Step 5:** Open the SpotOn Settings page in your browser (LMS → Settings → Plugins → SpotOn). The page load automatically detects the credentials, creates the account directory, registers the account, and starts the daemon. Your Spotify username should appear under Account Settings.

> **Important:** Do NOT restart LMS between steps 4 and 5. The startup sequence cleans up `__DISCOVER__/` before you can visit the Settings page. Always place the file while LMS is running, then load the Settings page.

### Docker / Kubernetes Notes

- The `__DISCOVER__` directory must be a **writable volume**, not a ConfigMap or read-only mount. SpotOn needs to rename it during account setup.
- Do not place `credentials.json` directly in a hash-named directory (e.g. `e20xxxxx/`). SpotOn only checks directories registered in its preferences — manual file placement skips that registration.
- If you previously created hash directories manually, remove them before following the steps above.

## Windows: Daemon Timeout or "Binary not found"

Make sure you are running the latest SpotOn version. Earlier versions had Windows-specific issues with daemon startup.

Update via: LMS Settings → Plugins → Check for Updates → Restart LMS.

### Windows Defender Firewall

You may need to add the SpotOn binary to the Windows Defender Firewall allowed apps list. The binary is located at:

```
C:\ProgramData\Lyrion\Cache\InstalledPlugins\Plugins\SpotOn\Bin\x86_64-win64\spoton.exe
```

Go to: Windows Security → Firewall & network protection → Allow an app through firewall → Add the path above.

If the issue persists after updating, collect a diagnostic bundle and open a [GitHub issue](https://github.com/stiefenm/spoton/issues).

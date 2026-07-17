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

### PKCE authorization fails or never completes

**Symptoms:** Clicking "Connect to Spotify" in SpotOn Settings opens a popup that closes without finishing, or the Settings page never picks up the new account after you approve access on Spotify's authorization page.

**Common causes and fixes:**
- **Popup blocked** — browsers block `window.open()` popups unless they're triggered directly by a click. Allow pop-ups for your LMS host and try again (SpotOn shows a reminder about this next to the auth button).
- **No Client ID configured** — PKCE requires your own Spotify Developer App Client ID (see [README Requirements](README.md#requirements)). Enter it in SpotOn Settings before starting the auth flow; the setup wizard walks you through creating one.
- **Redirect doesn't reach LMS** — SpotOn bounces the browser back to your LMS server via a GitHub Pages relay (`https://stiefenm.github.io/spoton/auth/`). If your phone/browser can't reach your LMS host directly (different network, VPN, restrictive firewall), the relay page falls back to a "copy this URL" box — paste it into the manual auth field on the SpotOn Settings page to complete the flow.
- **Redirect URI mismatch** — the Client ID's app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) must have `https://stiefenm.github.io/spoton/auth/` registered as an allowed Redirect URI, exactly as shown by the setup wizard.

### Re-authentication needed / token refresh fails

**Symptoms:** The Auth Health Dashboard (Status page) shows a warning for an account, Browse/Search return errors, or Connect stops working, with a token or credential error in the daemon log.

**Cause:** SpotOn refreshes your PKCE access token automatically in the background using the stored refresh token. If that refresh token becomes invalid (access revoked in your Spotify account, a corrupted token file, or an old v2.x account that never migrated), SpotOn can no longer refresh it and flags the account for re-authentication.

**What SpotOn already does automatically:** if the *Connect* credentials (used by librespot) get corrupted — e.g. after a crash or an abrupt Docker restart — SpotOn deletes and re-derives them from the stored PKCE tokens on its own, no action needed. Only a genuinely invalid/expired refresh token escalates to "needs re-authentication."

**Solution:**
1. Open **SpotOn Settings** and check the Auth Health Dashboard (also shown on the Status page) for the affected account
2. If it shows "needs re-authentication," follow the reconnect prompt and complete the PKCE flow again (see above)
3. If the account still fails after re-auth, clear its cache and start fresh:

```bash
# 1. Stop LMS

# 2. Remove the account's cache directory (find the account ID hash in
#    SpotOn Settings, or remove all account directories to reset everything):
#    Linux (typical path — adjust for your setup):
rm -rf /var/lib/squeezeboxserver/cache/spoton/<accountId>/

#    Docker (typical path):
rm -rf /config/cache/spoton/<accountId>/

# 3. Start LMS, then re-add the account via SpotOn Settings
```

4. If the issue persists, collect a diagnostic bundle and open an issue.

### Tracks skip or fail with "404" in logs (CDN errors)

**Symptoms:** Tracks skip to the next song after a few seconds, or playback fails entirely. The LMS log shows `Browse daemon 404` or `attempts exhausted, skipping to next track`.

**Cause:** Spotify occasionally returns bad CDN endpoints that respond with HTTP 404. This is a server-side issue on Spotify's end.

**Solutions:**
- **Update to v2.1.6 or later** — includes an upgraded librespot with CDN fallback (automatically tries the next CDN URL on 404) plus SpotOn's own 404 retry layer (3 attempts with 2s delay)
- If errors persist after updating, you can block specific bad CDN hosts via `/etc/hosts` — see the [forum thread](https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton) for known problematic hosts

## mDNS / ZeroConf: Guest Connect Discovery Only

Since v3.0, account authentication no longer uses mDNS at all — the PKCE flow runs entirely through the browser and SpotOn Settings, with no local-network requirement. This means setup behind Docker, VLANs, or a remote LMS install now just works, without the manual credential-transfer steps older SpotOn versions required.

mDNS (ZeroConf) is only still used for **guest Spotify Connect discovery**: it lets someone else on your LAN see your LMS player in their Spotify app's device list and hand off playback to it, without needing a SpotOn account of their own. This is optional and unrelated to your own account setup or normal Connect control, both of which go through Spotify's cloud regardless of network topology.

Guest discovery via mDNS won't work if:
- LMS runs in a **Docker container** (isolated network namespace) — use `--network host` if you want guest discovery to work
- LMS and the guest's phone are on **different VLANs/subnets**
- A **firewall** blocks mDNS (UDP port 5353)

None of the above affects setting up or using your own SpotOn account — only a guest trying to spontaneously discover your player via ZeroConf.

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

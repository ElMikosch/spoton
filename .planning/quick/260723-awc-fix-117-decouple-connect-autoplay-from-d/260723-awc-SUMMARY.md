---
status: complete
phase: quick
plan: 260723-awc
completed: 2026-07-23
commit: a3c18dd
---

# Quick Task 260723-awc: Fix #117 — Decouple Connect Autoplay from DSTM Provider

## What Changed

SpotOn no longer writes to the `plugin.dontstopthemusic` pref namespace. Three problematic code paths removed:

1. **Settings/Player.pm** — Removed DSTM provider write on save (was unconditionally overwriting user's DSTM choice). Removed readback that derived autoplay checkbox from DSTM provider. Added read-only DSTM status pass-through for template display.

2. **DaemonManager.pm** — Removed auto-configure block (60s watchdog that re-enabled DSTM on all players, including those where user explicitly disabled it due to falsy `provider=0`).

3. **Plugin.pm** — Comment updated. Default `enableAutoplay => 1` retained (now means Connect autoplay only). DSTM handler registration unchanged.

4. **player.html** — Added read-only DSTM status display below autoplay checkbox (active/hint based on current provider).

5. **strings.txt** — Updated AUTOPLAY_ENABLED_DESC to Connect-only wording. Added DSTM_STATUS_ACTIVE and DSTM_STATUS_HINT strings (11 languages each).

## Decisions

- No migration needed — existing DSTM provider prefs persist unchanged
- Matches ecosystem pattern: Spotty, Qobuz, TIDAL all register DSTM handlers without auto-setting the provider
- `enableAutoplay` default stays ON (correct for Connect — mirrors Spotify app behavior)

## Files Modified

- `Plugins/SpotOn/Settings/Player.pm` — removed DSTM write + readback, added read-only status
- `Plugins/SpotOn/Unified/DaemonManager.pm` — removed auto-configure block
- `Plugins/SpotOn/Plugin.pm` — comment update only
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html` — DSTM status display
- `Plugins/SpotOn/strings.txt` — updated + 2 new string blocks

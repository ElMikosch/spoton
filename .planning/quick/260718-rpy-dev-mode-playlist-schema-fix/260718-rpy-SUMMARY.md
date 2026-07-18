---
phase: quick-260718-rpy
plan: 01
status: complete
started: 2026-07-18T18:00:00Z
completed: 2026-07-18T20:30:00Z
commit: 26e8c1a
---

# Quick Task 260718-rpy: Dev Mode Playlist Schema Fix — Summary

## What Was Done

Added `_normalizeLibraryItem($item, $key)` helper to Plugin.pm that normalizes Spotify's Development Mode response schema (`{item: {...}}`) back to the Extended Quota format (`{track/album/show: {...}}`) before downstream consumers access the data.

Applied at 8 consumer sites:
- Plugin.pm: `_recentlyPlayedFeed`, `_savedTracksFeed` (×2), `_savedAlbumsFeed`, `_savedShowsFeed`, `_playlistFeed` (×2)
- ProtocolHandler.pm: `explodePlaylist`

Added defensive `grep { defined $_->{key} }` guards at 3 sites that previously lacked them (recently played, saved tracks single-page, saved albums).

## Root Cause

Spotify serves two different response schemas for `/playlists/{id}/items` and other library endpoints depending on Client ID quota mode:
- Extended Quota (bundled ID): `items[].track` = full track object
- Development Mode (own ID): `items[].item` = track object, `track` = boolean

SpotOn assumed the Extended Quota format everywhere, causing empty results for Dev Mode users. Reported by woorszt in #119.

## Review

- Plan reviewed by Fable 5: APPROVE WITH CHANGES
- Changes adopted: parametric helper (track/album/show), verify via `prove t/05_perl_syntax.t`
- Grep guard decision: YES, add at all sites (Fable recommended)

## Testing

- Own Client ID (Dev Mode): own playlists display correctly, tracks play
- Bundled Client ID (Extended Quota): own playlists display correctly, no regression
- All 22 test files, 741 assertions: PASS

## Side Finding

Bundled Client ID does not list foreign (followed) playlists in `me/playlists` — separate issue, not caused by this fix. Filed as #120.

## Files Modified

- `Plugins/SpotOn/Plugin.pm` — +24 lines (helper + 7 call sites)
- `Plugins/SpotOn/ProtocolHandler.pm` — +3 lines (1 call site)

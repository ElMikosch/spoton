---
id: 260723-fkg
title: "Fix #126: Connect seek/change progress bar resync"
scope: Plugins/SpotOn/Connect.pm
type: bugfix
tasks: 2
---

# Fix #126: Connect seek/change progress bar resync

## Problem

LMS `executeDone()` pops the `spottyconnect` notification off the queue when the handler never calls `setStatusDone()`. Branches with nested requests (volume, resume, start) accidentally survive via the nested request's notification. The `seek` and `change` (normal case — player already playing) branches have no nested request, so their notification is silently dropped — no status push to JiveLite/SqueezePlay subscribers.

## Root Cause Analysis (Fable 5)

- `Request.pm:1905-1914`: `executeDone()` pops notification if `!isStatusDone()`
- Seek handler only mutates `$song->startOffset()` — no nested `->execute()` call
- Change handler only issues `['pause', 0]` when `!$client->isPlaying` — common case (player already playing during track change) has no nested request
- `notifyFromArray(['newmetadata'])` is the established pattern (already used at line 1102 in `_fetchTrackMetadata`)
- `['time', N]` MUST NOT be used — `notifyFromArray` cannot be source-marked, and `_onSeek` subscribes to `['time']`, which would echo it to the binary as `/control/seek` → infinite seek loop
- Server-side notification coalescing (`killOneTimer` + re-arm at +0.3s) prevents flooding on rapid seek

## Tasks

### T-01: Add notifyFromArray to seek handler

**Files:** `Plugins/SpotOn/Connect.pm`
**Action:** After `$song->startOffset($position - $elapsed)` at ~line 612, add `Slim::Control::Request::notifyFromArray($client, ['newmetadata'])` so JiveLite resyncs the progress bar on seek events.
**Verify:** `grep -n 'notifyFromArray.*newmetadata' Plugins/SpotOn/Connect.pm` shows the new line inside the seek handler block
**Done:** The seek handler triggers a status push after adjusting startOffset

### T-02: Add notifyFromArray to change handler

**Files:** `Plugins/SpotOn/Connect.pm`
**Action:** After `$client->pluginData(progress => 0)` at ~line 862, add `Slim::Control::Request::notifyFromArray($client, ['newmetadata'])` so the progress bar resets immediately on track change — even if the async metadata fetch fails (429 backoff during rapid skips).
**Verify:** `grep -n 'notifyFromArray.*newmetadata' Plugins/SpotOn/Connect.pm` shows the new line inside the change handler block
**Done:** The change handler triggers an immediate status push before the async metadata fetch

## What NOT to do

- Do NOT add `streamingProgressBar()` — it only sets duration (DB write), not position; operates on `streamingSong()` not `playingSong()`
- Do NOT add `$song->duration($duration)` — seek handler has no `$duration`; setting it to undef would hide the progress bar
- Do NOT add `currentPlaylistUpdateTime()` — would signal "playlist changed" causing refetch churn on every seek
- Do NOT use `notifyFromArray($client, ['time', N])` — would create an infinite seek loop via `_onSeek` subscription

---
status: complete
---

# Fix #126: Connect seek/change progress bar resync — Summary

## What Changed

Added `Slim::Control::Request::notifyFromArray($client, ['newmetadata'])` to two Connect.pm event handlers that were missing status push notifications:

1. **Seek handler** (line 613): After `$song->startOffset()` adjustment — JiveLite now resyncs progress bar on seek events from Spotify app
2. **Change handler** (line 864): After progress reset — progress bar resets immediately on track change, even if the async metadata fetch fails (429 backoff during rapid skips)

## Root Cause

LMS `executeDone()` (Request.pm:1905-1914) pops the `spottyconnect` notification off the queue when the handler never calls `setStatusDone()`. Branches with nested requests (volume→`mixer volume`, resume→`pause 0`, start→`playlist play`) accidentally survive via the nested request's own notification. The `seek` and `change` (normal case) branches had no nested request, so their notification was silently dropped — no status push to JiveLite/SqueezePlay subscribers.

## Files Modified

- `Plugins/SpotOn/Connect.pm` — 2 lines added (seek handler line 613, change handler line 864)

## Decisions

- Only `notifyFromArray(['newmetadata'])` added — NOT `streamingProgressBar()` (cargo-cult: only sets duration, not position), NOT `$song->duration()` (seek handler has no duration), NOT `currentPlaylistUpdateTime()` (would cause playlist refetch churn)
- `['newmetadata']` chosen over `['time', N]` to avoid infinite seek loop (`_onSeek` subscribes to `['time']` and would echo back to binary)
- Server-side notification coalescing (`killOneTimer` + re-arm +0.3s) prevents flooding on rapid seek

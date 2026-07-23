# Phase 58: Connect Position Sync Fix — Context

**Gathered:** 2026-07-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Fix two interrelated bugs in the Connect position sync pipeline:

1. **Rust (Root Cause):** `needs_position_sync` is cleared prematurely in `TrackChanged` Some→Some, so mid-song Connect resume never emits a seek event with the real position.
2. **Perl (Regression from #126 fix):** `notifyFromArray` in the change handler pushes position=0 before the real position is known, causing visible progress bar divergence.

Both bugs existed before #126, but our fix (adding `notifyFromArray` to the change handler) made the Perl side actively harmful by pushing a definitive wrong position instead of silently drifting.

NOT in scope: Seek handler `notifyFromArray` (line 613) — confirmed correct, no regression.

</domain>

<decisions>
## Implementation Decisions (from Fable 5 Analysis)

### Part A — Rust Fix (connect.rs)
- **Remove** `self.needs_position_sync.store(false, Ordering::Release)` from `TrackChanged` Some→Some branch (line 247) — preserve the pending session-start sync across the change event
- **Add** position sync check to `Playing` Some→Some branch (currently line 158-163): after emitting `change`, check `needs_position_sync.swap(false)` and emit `seek` if `position_ms / 1000.0 > 1.0`
- Safety: `needs_position_sync` is only ever set true at session start (None→Some), so normal mid-playback skips are unchanged. The `secs > 1.0` guard prevents spurious seek events for tracks genuinely starting at 0.
- This requires a binary rebuild (CI triggered by librespot-spoton/ changes)

### Part B — Perl Fix (Connect.pm)
- **Remove** `notifyFromArray($client, ['newmetadata'])` from the change handler (line 864)
- **Add** `notifyFromArray($client, ['newmetadata'])` to `_fetchTrackMetadata`'s two failure exit paths:
  1. Stale-API path (before line 1004's `_finishNewTrack`): add `notifyFromArray` so the progress reset from the change handler is pushed even when the API response is discarded
  2. No-trackInfo path (inside the `unless` at line 1010): add `notifyFromArray` so 429/parse-error/no-data failure cases push the notification
  3. The no-`$song` path (line 1016) can skip — nothing to display
- The success path already has `notifyFromArray` at line 1104 — no change needed there
- This preserves the rapid-skip fix (429 backoff → failure path → notification fires) without the regression (no active push of position=0 in the change handler)

### Ordering
- Part B (Perl) is safe to ship standalone as a hotfix — removes the regression immediately
- Part A (Rust) is the proper root-cause fix — makes mid-song resume position actually correct for the first time
- Both parts are independent (no cross-dependency) but complementary

### Verification
- API::Client callback is **guaranteed** to invoke `$cb` on every failure path, including active 429 backoff (line 1289-1292 returns immediately with error)
- `connectStartTime` could gate the change-handler notify (same pattern as stop handler grace period at line 901), but the failure-path approach makes this unnecessary
- Timer-based delay (500ms) was considered and rejected — no seek ever arrives in the broken scenario, so the timer would always fire with wrong position

</decisions>

<specifics>
## Specific Code Locations

### Rust (connect.rs)
- `TrackChanged` Some→Some: line 246-251, specifically line 247 (`needs_position_sync.store(false)`)
- `Playing` Some→Some: line 158-163 (needs position sync check added here)
- `Playing` same-id: line 150-156 (existing sync check — reference pattern)
- `TrackChanged` None→Some: line 252-264 (sets `needs_position_sync = true` — must NOT be touched)

### Perl (Connect.pm)
- Change handler `notifyFromArray`: line 864 (REMOVE)
- `_fetchTrackMetadata` stale-API exit: line 1003-1005 (ADD notify before `_finishNewTrack`)
- `_fetchTrackMetadata` no-trackInfo exit: line 1010-1012 (ADD notify before `_finishNewTrack`)
- `_fetchTrackMetadata` no-song exit: line 1016-1018 (SKIP — no song = nothing to push)
- `_fetchTrackMetadata` success path: line 1104 (existing notify — no change)
- Seek handler `notifyFromArray`: line 613 (KEEP — confirmed correct)

</specifics>

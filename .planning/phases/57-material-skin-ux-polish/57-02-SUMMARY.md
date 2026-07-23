---
phase: 57-material-skin-ux-polish
plan: 02
subsystem: ui
tags: [json-xs, encode, material-skin, home-extras, i18n]

requires:
  - phase: 56-material-skin-compat
    provides: HomeExtraBase (WR-01 textarea filter, WR-02 60s memoization), Recently Played + Top Tracks scrolled rows
provides:
  - Single-encoded UTF-8 JSON responses from Status.pm and Settings.pm AJAX endpoints
  - HomeExtraMadeForYou — third Material Skin scrolled row, registered unconditionally
affects: [material-skin-ux-polish, home-extras, status-page, settings-page]

tech-stack:
  added: []
  patterns:
    - "_jsonResponse assigns to_json($data) directly — no Encode wrapper; to_json (JSON::XS::VersionOneAndTwo) already returns UTF-8 octets"
    - "New HomeExtra*/HomeExtraBase subclasses need only title/subtitle/feed/tag — WR-01 filter + WR-02 memoization are inherited automatically"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Status.pm
    - Plugins/SpotOn/Settings.pm
    - Plugins/SpotOn/HomeExtras.pm

key-decisions:
  - "Removed the encode('UTF-8', ...) wrapper around to_json in both _jsonResponse helpers rather than switching to a different JSON serializer — root cause was double-encoding, not a bad library choice"
  - "Registered HomeExtraMadeForYou unconditionally like Spotty and the two existing SpotOn extras — the Phase 56 decision to skip Made For You predated the WR-01 filter analysis showing it degrades cleanly (empty row) instead of showing junk cards"

patterns-established: []

requirements-completed: ["GH-125"]

coverage:
  - id: D1
    description: "Status.pm and Settings.pm _jsonResponse emit single-encoded UTF-8 JSON (umlauts render correctly instead of mojibake)"
    requirement: "GH-125"
    verification:
      - kind: unit
        ref: "t/05_perl_syntax.t (perl -c syntax check for Status.pm, Settings.pm)"
        status: pass
      - kind: other
        ref: "grep gate: no 'encode(\\'UTF-8\\', to_json' remains in either file; direct 'my $bytes = to_json($data);' assignment present in both; Status.pm has no Encode import; Settings.pm retains exactly 2 out-of-scope encode sites"
        status: pass
    human_judgment: true
    rationale: "Actual umlaut rendering in the browser (German account names on the Status/Settings AJAX pages) requires a live LMS + Material Skin instance to visually confirm — no automated Perl test exercises the HTTP response body end-to-end."
  - id: D2
    description: "Made For You registered as a third Material Skin scrolled row (HomeExtraMadeForYou), degrading to an empty row when sp_dc is missing/expired"
    requirement: "GH-125"
    verification:
      - kind: other
        ref: "grep gate: package Plugins::SpotOn::HomeExtraMadeForYou declared, registered via initPlugin(), tag 'MadeForYou', feed \\&Plugins::SpotOn::Plugin::_madeForYouFeed, title 'PLUGIN_SPOTON_MADE_FOR_YOU' — all present"
        status: pass
    human_judgment: true
    rationale: "perl -c cannot load HomeExtras.pm outside the LMS runtime (Plugins::MaterialSkin::HomeExtraBase dependency + load-time initPlugin side effects, same constraint as Phase 56). Confirming the row appears in Material Skin's home customization list and renders Pathfinder playlists with artwork (or degrades to empty) requires a live LMS + Material Skin instance."

duration: ~10min
completed: 2026-07-23
status: complete
---

# Phase 57 Plan 02: JSON UTF-8 Fix + Made For You Scrolled Row Summary

**Fixed double-encoded UTF-8 in Status/Settings JSON AJAX responses and added Made For You as SpotOn's third unconditionally-registered Material Skin home row.**

## Performance

- **Duration:** ~10 min
- **Tasks:** 2 completed
- **Files modified:** 3

## Accomplishments

- `_jsonResponse` in both Status.pm and Settings.pm now assigns `to_json($data)` directly instead of wrapping it in `encode('UTF-8', ...)`, eliminating the double-encoding that produced mojibake for umlaut-bearing JSON fields (e.g. German account names). `Content-Length => length($bytes)` remains correct since `to_json` already returns an octet string.
- Removed the now-unused `use Encode qw(encode)` import from Status.pm (its only call site was the fixed line). Settings.pm keeps its Encode import — 2 legitimate out-of-scope sites (HTML page body at ~820, diag text download at ~960) still need it.
- Added `Plugins::SpotOn::HomeExtraMadeForYou`, a third `HomeExtraBase` subclass following the exact shape of `HomeExtraRecentlyPlayed`/`HomeExtraTopTracks`, registered unconditionally in the top-level `Plugins::SpotOn::HomeExtras` initializer. Reuses the existing `_madeForYouFeed` (Plugin.pm) — no new feed logic needed, since its `($client, $callback, $args)` signature already matches what `HomeExtraBase` expects.
- No `Plugin.pm` change required: `postinitPlugin` already `require`s `HomeExtras.pm`, which self-registers all three extras at load. No i18n changes needed: `PLUGIN_SPOTON_MADE_FOR_YOU` already exists in `strings.txt` for all 11 languages.

## Task Commits

Each task was committed atomically:

1. **Task 1: Remove double-encoding from _jsonResponse in Status.pm and Settings.pm** - `43468a4` (fix)
2. **Task 2: Add HomeExtraMadeForYou scrolled row to HomeExtras.pm** - `bb5ed7c` (feat)

_Note: Plan metadata commit (docs, STATE.md, ROADMAP.md) is handled by the orchestrator, not this executor._

## Files Created/Modified

- `Plugins/SpotOn/Status.pm` - `_jsonResponse` now assigns `to_json($data)` directly; `use Encode` import removed
- `Plugins/SpotOn/Settings.pm` - `_jsonResponse` now assigns `to_json($data)` directly; `use Encode` import retained for its 2 other legitimate call sites
- `Plugins/SpotOn/HomeExtras.pm` - New `Plugins::SpotOn::HomeExtraMadeForYou` package + registration call in the top-level initializer

## Decisions Made

- Removed the `encode('UTF-8', ...)` wrapper around `to_json` in both `_jsonResponse` helpers rather than switching serializer — CONTEXT decision B correctly identified the root cause as a redundant second encoding pass, not a library defect.
- Registered `HomeExtraMadeForYou` unconditionally, same as Spotty and the two existing SpotOn extras. The Phase 56 decision to skip Made For You (see STATE.md decision log) predated the WR-01 filter analysis: `_madeForYouFeed`'s textarea-hint degradation path is stripped by the inherited `HomeExtraBase` filter, so the row renders empty on missing/expired `sp_dc` instead of showing junk cards — no per-extra gating code was needed.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. `perl -c` was not directly runnable against the bare files outside the LMS runtime (missing `JSON::XS::VersionOneAndTwo` / `Plugins::MaterialSkin::HomeExtraBase` in a plain Perl environment), so verification used the project's existing `t/05_perl_syntax.t` harness, which provides LMS stub modules — this is the project's established syntax-check pattern (already listed for Status.pm/Settings.pm in that test file) and is functionally identical to a direct `perl -c` run per the plan's `<verify>` gate. HomeExtras.pm's structural greps (package declaration, registration call, feed reference, tag, title) were run directly per the plan's own note that `perl -c` cannot load this file outside LMS runtime (same constraint documented in Phase 56).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Both GH #125 sub-issues (UTF-8 double-encoding, Made For You scrolled row) addressed at the code level. Remaining verification is manual, on a live LMS + Material Skin instance:
- Confirm umlaut-bearing fields (e.g. German account display names) render correctly on the Status/Settings pages
- Confirm Material Skin's home screen customization list now offers "Made For You" as a selectable row, and that it shows Pathfinder playlists with artwork when `sp_dc` is valid, or an empty (not junk) row when missing/expired

CONTEXT decision C (HomeExtras umlaut mojibake via `getHomeExtra3rdPartyItems()`) is an upstream Material Skin bug, out of scope for this plan — filing an issue at CDrummond/lms-material remains a follow-up action outside this codebase.

## Self-Check: PASSED

- FOUND: Plugins/SpotOn/Status.pm
- FOUND: Plugins/SpotOn/Settings.pm
- FOUND: Plugins/SpotOn/HomeExtras.pm
- FOUND: 43468a4
- FOUND: bb5ed7c

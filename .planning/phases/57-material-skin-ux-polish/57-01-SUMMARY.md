---
phase: 57-material-skin-ux-polish
plan: 01
subsystem: ui
tags: [opml, material-skin, icons, pil, home-feed]

requires:
  - phase: 56-material-skin-compat
    provides: Material Skin grid/cover toggle fix pattern (image key on every menu item), 512x512 gray+alpha icon precedent (home.png, podcasts.png, song.png, account.png)
provides:
  - 3 new PNG icon assets (toptracks.png copied from Spotty, recently.png + madeforyou.png generated)
  - image keys on all 4 _homeFeed push sites (Recently Played, Made For You expired branch, Made For You normal branch, Top Tracks)
affects: [material-skin-ux-polish, home-feed]

tech-stack:
  added: []
  patterns:
    - "Home feed icon pattern: image => 'plugins/SpotOn/html/images/{name}.png' on every _homeFeed push site, same convention as Phase 56's handleFeed"
    - "Icon generation via throwaway PIL script (not committed): 4x oversample + LANCZOS downscale to 512x512 LA mode, white glyph on transparent background"

key-files:
  created:
    - Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/toptracks.png
    - Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/recently.png
    - Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/madeforyou.png
  modified:
    - Plugins/SpotOn/Plugin.pm

key-decisions:
  - "toptracks.png copied unmodified from Spotty (same source/style precedent as Phase 56's home.png/podcasts.png)"
  - "recently.png (clock glyph) and madeforyou.png (sparkle glyph) generated fresh via PIL since Spotty has no equivalent icons -- style-matched to existing 512x512 gray+alpha SpotOn icons"
  - "Both Made For You _homeFeed push sites (expired branch and normal branch) got the same madeforyou.png key -- missing either would silently break the grid/cover toggle depending on sp_dc state"

patterns-established:
  - "PIL icon generation via scratchpad-only script (never committed) -- render at 4x scale then LANCZOS-downscale for antialiasing, verify glyph coverage is between 1% and 40% of pixels to guard against blank/solid renders"

requirements-completed: ["GH-124"]

coverage:
  - id: D1
    description: "toptracks.png icon asset (512x512 gray+alpha) + image key wired to the Top Tracks entry in _homeFeed"
    requirement: "GH-124"
    verification:
      - kind: unit
        ref: "prove t/05_perl_syntax.t (Plugin.pm passes perl -c via stub-module harness)"
        status: pass
      - kind: other
        ref: "file Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/toptracks.png -- 512x512, 8-bit gray+alpha"
        status: pass
      - kind: other
        ref: "grep -c plugins/SpotOn/html/images/toptracks.png Plugins/SpotOn/Plugin.pm == 1"
        status: pass
    human_judgment: false
  - id: D2
    description: "recently.png (clock glyph) and madeforyou.png (sparkle glyph) generated and wired to Recently Played + both Made For You push sites in _homeFeed"
    requirement: "GH-124"
    verification:
      - kind: unit
        ref: "prove t/05_perl_syntax.t (Plugin.pm passes perl -c via stub-module harness)"
        status: pass
      - kind: other
        ref: "file check: both PNGs 512x512, 8-bit gray+alpha"
        status: pass
      - kind: other
        ref: "grep -c recently.png == 1, grep -c madeforyou.png == 2 in Plugin.pm"
        status: pass
      - kind: other
        ref: "python3 PIL glyph-coverage guard: 0.01 < alpha-coverage < 0.40 for both PNGs"
        status: pass
    human_judgment: true
    rationale: "Automated checks confirm file format, dimensions, image-key wiring, and non-blank glyph coverage, but whether the glyphs visually read as a recognizable clock (recently.png) and Made-For-You sparkle (madeforyou.png), and whether the Material Skin grid/cover toggle actually renders correctly in a live LMS instance, requires human visual/functional confirmation."

duration: ~15min
completed: 2026-07-23
status: complete
---

# Phase 57 Plan 01: Home Feed Icons Summary

**Added image keys + 3 new PNG icons (toptracks copied from Spotty, recently/madeforyou generated via PIL) to all 4 `_homeFeed` push sites, restoring Material Skin's grid/cover toggle on the SpotOn Home feed**

## Performance

- **Duration:** ~15 min (includes a mid-plan tracer feedback-gate checkpoint pause for human verification)
- **Started:** 2026-07-23T09:43:00Z (approx.)
- **Completed:** 2026-07-23T09:58:32Z
- **Tasks:** 2/2
- **Files modified:** 4 (1 modified, 3 created)

## Accomplishments

- Restored Material Skin's grid/cover-view toggle on the SpotOn Home feed by adding `image` keys to all 4 `_homeFeed` push sites (Recently Played, Made For You expired branch, Made For You normal branch, Top Tracks) — GH #124 follow-up
- Added `toptracks.png`, copied unmodified from Spotty's existing icon (512x512, gray+alpha, same visual style as all existing SpotOn menu icons)
- Generated `recently.png` (clock glyph) and `madeforyou.png` (sparkle glyph, Spotify's Made-For-You iconography) fresh via a throwaway PIL script, matching the established icon style
- Verified both Made For You push sites (expired sp_dc branch and normal branch) carry the same image key so the grid toggle survives sp_dc expiry

## Task Commits

Each task was committed atomically:

1. **Task 1: Tracer — toptracks.png asset + image key on the Top Tracks entry** - `51d9621` (feat)
2. **Task 2: Generate recently.png + madeforyou.png, wire remaining 3 image keys** - `8f52612` (feat)

**Plan metadata:** committed separately by the orchestrator (docs commit)

## Files Created/Modified

- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/toptracks.png` - Copied from Spotty's existing icon (512x512, gray+alpha)
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/recently.png` - Generated clock glyph icon (512x512, LA mode, white on transparent)
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/madeforyou.png` - Generated 4-pointed sparkle glyph icon (512x512, LA mode, white on transparent)
- `Plugins/SpotOn/Plugin.pm` - Added `image =>` key to all 4 `_homeFeed` push sites (lines ~1255, ~1275, ~1281, ~1291)

## Decisions Made

- `toptracks.png` copied unmodified from Spotty rather than regenerated — matches Phase 56 precedent (home.png/podcasts.png/song.png/account.png were all copied the same way) and guarantees exact style match since Spotty already has this exact icon.
- `recently.png` and `madeforyou.png` generated fresh via PIL since Spotty has no equivalent icons for these concepts. Style contract matched to the existing directory: 512x512, LA (grayscale+alpha) mode, fully transparent background, white glyph, rendered at 4x oversample with LANCZOS downscale for antialiasing.
- Both Made For You push sites (expired sp_dc branch at ~line 1274 and normal branch at ~line 1280) received the identical `madeforyou.png` key — CONTEXT decision A+E explicitly calls out both sites since missing either would silently break the grid toggle depending on account sp_dc state.

## Deviations from Plan

None - plan executed exactly as written. One process note: `perl -c Plugins/SpotOn/Plugin.pm` cannot run directly in this sandbox because `Log::Log4perl` and other LMS core Perl modules aren't installed outside a real LMS environment (pre-existing environment limitation, confirmed unrelated to this change via `git stash` A/B test). Verification was instead performed via the project's existing `t/05_perl_syntax.t`, which wraps `Plugin.pm` with stub modules specifically for this purpose and ran clean for all 12 tracked `.pm` files both before and after each task's changes.

## Issues Encountered

None. A tracer feedback-gate checkpoint paused execution after Task 1 (per the interactive-mode tracer protocol) for human confirmation of the asset-path-to-OPML-image-key pipeline before expanding to the remaining 3 icons; the coordinator verified the toptracks.png rendering and image-key placement, and execution resumed to Task 2 without changes.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All 4 `_homeFeed` items now carry image keys; Material Skin's grid/cover toggle should be functional on the SpotOn Home feed in all sp_dc states (empty/secrets_down items are hidden entirely and don't affect the toggle; expired/valid items both now have icons)
- Default (non-Material) skins will render these 3 new PNGs directly as menu icons
- Manual verification recommended on a live LMS + Material Skin instance: confirm the grid/cover toggle appears and the 4 icons render as expected (clock, sparkle, "123", plus existing icons)
- Remaining Phase 57 scope (Status.pm UTF-8 double-encoding fix, HomeExtras Made For You scrolled row, upstream Material Skin issue filing) is tracked in separate plans per 57-CONTEXT.md decisions B/C/D

---
*Phase: 57-material-skin-ux-polish*
*Completed: 2026-07-23*

## Self-Check: PASSED

All 3 created PNG files confirmed present on disk (toptracks.png, recently.png, madeforyou.png). Both task commits (51d9621, 8f52612) confirmed present in git log.

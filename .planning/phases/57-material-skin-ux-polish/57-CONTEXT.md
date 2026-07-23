# Phase 57: Material Skin UX Polish — Context

**Gathered:** 2026-07-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Follow-up to Phase 56 (Material Skin Compatibility). Addresses remaining feedback from #124 and #125 after v3.2.0 shipped.

Scope: Home feed icons, UTF-8 encoding fix, Made For You scrolled row, upstream MS issue.
NOT in scope: Any new Spotify API features, auth changes, or Connect modifications.

</domain>

<decisions>
## Implementation Decisions (from Fable 5 Research)

### A+E: Home Feed Icons
- Add `image =>` key to all items in `_homeFeed` (Plugin.pm:1250-1294)
- Made For You has 4 push sites (expired branch line 1274 + normal branch line 1280) — all need `image`
- Create 3 new PNG icon assets: recently.png, madeforyou.png, toptracks.png
- Use Spotty's PNGs as style reference (same dimensions, similar visual language)
- Pattern: `image => 'plugins/SpotOn/html/images/recently.png'` etc.

### B: Status.pm UTF-8 Double-Encoding Fix
- Remove `encode('UTF-8', ...)` wrapper from `_jsonResponse` — `to_json()` already returns UTF-8 bytes
- Two identical sites: Status.pm:321 and Settings.pm:1003
- `use Encode` in Status.pm becomes removable after fix
- Settings.pm:820/960 (HTML/diag-text encoding) are separate concerns — out of scope

### C: HomeExtras Umlaut Encoding — UPSTREAM BUG
- Confirmed upstream Material Skin bug in `getHomeExtra3rdPartyItems()`
- `to_json()` produces UTF-8 bytes → outer JSON-RPC serializer re-encodes → mojibake
- Spotty has the same problem
- No SpotOn-side workaround possible
- Action: File upstream issue at CDrummond/lms-material with repro + fix suggestion

### D: Made For You as Scrolled Row
- Add `HomeExtraMadeForYou` subclass in HomeExtras.pm
- Register unconditionally (same as Spotty) — WR-01 textarea filter already strips empty entries
- sp_dc dependency handled by existing `_madeForYouFeed` state gating
- Pathfinder items have real artwork → good grid display
- Registration in `postinitPlugin` (Plugin.pm:300-309), add to existing require block

</decisions>

<specifics>
## Specific References

- `_homeFeed`: Plugin.pm:1250-1294
- `_jsonResponse`: Status.pm:321, Settings.pm:1003
- HomeExtras.pm: existing Recently Played + Top Tracks registration
- HomeExtraBase: `Plugins::MaterialSkin::HomeExtraBase` parent class
- Spotty reference: `/home/sti/spotty-ng/Spotty-Plugin/HomeExtras.pm` (5 unconditional rows)
- Icon assets: `Plugins/SpotOn/HTML/EN/plugins/SpotOn/html/images/`
- Phase 56 plan: `.planning/phases/56-material-skin-compat/56-01-PLAN.md`

</specifics>

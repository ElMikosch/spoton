---
phase: quick-260718-rpy
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Plugins/SpotOn/Plugin.pm
  - Plugins/SpotOn/ProtocolHandler.pm
autonomous: true
must_haves:
  truths:
    - Library items with Dev Mode schema (item key instead of track/album/show key) are normalized before consumption
    - Extended Quota schema (track/album/show keys) continues to work unchanged
    - All 8 consumer sites handle both schemas identically
  artifacts:
    - Plugins/SpotOn/Plugin.pm with _normalizeLibraryItem helper
    - Plugins/SpotOn/ProtocolHandler.pm with normalization applied at explodePlaylist
  key_links:
    - _normalizeLibraryItem must run BEFORE grep/filter on track/album/show key at every consumer site
    - ProtocolHandler calls Plugin helper via established cross-module pattern
---

<objective>
Fix Spotify Development Mode library item schema incompatibility.

Spotify serves two response schemas for playlist/library item endpoints depending on quota mode:
- Extended Quota (bundled Client ID): items wrapped as {track: {id, name, ...}} / {album: {id, name, ...}} / {show: {id, name, ...}}
- Development Mode (user's own Client ID): items wrapped as {item: {id, name, ...}, track: true} (generic `item` key replaces type-specific key)

SpotOn currently assumes the Extended Quota schema everywhere, causing empty playlists and broken library feeds for Dev Mode users.

Purpose: Make SpotOn schema-agnostic so both Extended Quota and Dev Mode Client IDs work.
Output: Defensive normalization at all 8 consumer sites via a shared parametric helper.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@Plugins/SpotOn/Plugin.pm
@Plugins/SpotOn/ProtocolHandler.pm
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add _normalizeLibraryItem helper and fix all Plugin.pm consumer sites</name>
  <files>Plugins/SpotOn/Plugin.pm</files>
  <action>
Add a private helper sub _normalizeLibraryItem that normalizes a single playlist/library API response item in-place. The function takes two arguments: a hashref (single element from the items array) and the expected key name (string: 'track', 'album', or 'show'). Logic:

- If the item has a hashref under the key "item" AND either lacks the expected key entirely or has the expected key set to a non-hashref value (e.g. boolean true in Dev Mode): copy the "item" value to the expected key. This makes the item look like Extended Quota format for all downstream consumers.
- If the item already has a hashref under the expected key (Extended Quota): do nothing.
- Use explicit ref() check: ref($item->{item}) eq 'HASH' and ref($item->{$key}) ne 'HASH'
- Return the item (for use in map chains).

Place this helper immediately before the existing _trackItem sub (around line 980).

Then apply it at these 7 consumer sites in Plugin.pm:

Site 1 — _recentlyPlayedFeed (line 1303):
Currently: `map { _trackItem($client, $_->{track}) } @{ $data->{items} || [] }`
Change to: normalize each item first, add grep guard, then map:
  `map { _trackItem($client, $_->{track}) } grep { defined $_->{track} } map { _normalizeLibraryItem($_, 'track') } @{ $data->{items} || [] }`

Site 2 — _savedTracksFeed play-all (line 1482-1483):
Currently: `map { _trackItem(..., $_->{track}, ...) } grep { defined $_->{track} } @{$allItems}`
Change to: insert normalize before grep:
  `map { _trackItem(..., $_->{track}, ...) } grep { defined $_->{track} } map { _normalizeLibraryItem($_, 'track') } @{$allItems}`

Site 3 — _savedTracksFeed single-page (line 1514):
Currently: `map { _trackItem($client, $_->{track}) } @{ $data->{items} || [] }`
Change to: normalize + add grep guard:
  `map { _trackItem($client, $_->{track}) } grep { defined $_->{track} } map { _normalizeLibraryItem($_, 'track') } @{ $data->{items} || [] }`

Site 4 — _savedAlbumsFeed (line 1540):
Currently: `map { _albumItem($client, $_->{album}) } @{ $data->{items} || [] }`
Change to: normalize + add grep guard:
  `map { _albumItem($client, $_->{album}) } grep { defined $_->{album} } map { _normalizeLibraryItem($_, 'album') } @{ $data->{items} || [] }`

Site 5 — saved shows (line 1739-1740):
Currently: `map { _showItem($client, $_->{show}) } grep { defined $_->{show} } @{ $data->{items} || [] }`
Change to: insert normalize before grep:
  `map { _showItem($client, $_->{show}) } grep { defined $_->{show} } map { _normalizeLibraryItem($_, 'show') } @{ $data->{items} || [] }`

Site 6 — _playlistFeed play-all (line 2805-2806):
Currently: `map { _trackItem(..., $_->{track}, ...) } grep { defined $_->{track} } @{$allItems}`
Change to: insert normalize before grep:
  `map { _trackItem(..., $_->{track}, ...) } grep { defined $_->{track} } map { _normalizeLibraryItem($_, 'track') } @{$allItems}`

Site 7 — _playlistFeed single-page (line 2844-2845):
Currently: `map { _trackItem($client, $_->{track}) } grep { defined $_->{track} } @{ $data->{items} || [] }`
Change to: insert normalize before grep:
  `map { _trackItem($client, $_->{track}) } grep { defined $_->{track} } map { _normalizeLibraryItem($_, 'track') } @{ $data->{items} || [] }`

The _flushDeferredMeta consumer (line 59) reads $p->{track} from already-extracted deferred metadata entries built by _trackItem. Since _trackItem receives the already-normalized track object, _flushDeferredMeta requires no changes.

Do NOT touch _transformPlaylistContents in Client.pm — that is the Pathfinder/GraphQL path and has its own normalization.
  </action>
  <verify>
    <automated>cd /home/sti/spoton && prove t/05_perl_syntax.t 2>&amp;1 | tail -10 &amp;&amp; grep -c '_normalizeLibraryItem' Plugins/SpotOn/Plugin.pm</automated>
  </verify>
  <done>
    - _normalizeLibraryItem helper exists and handles both schemas for track/album/show keys
    - All 7 Plugin.pm consumer sites call the normalizer before accessing the type-specific key
    - Perl syntax check passes
  </done>
</task>

<task type="auto">
  <name>Task 2: Fix ProtocolHandler.pm explodePlaylist consumer site</name>
  <files>Plugins/SpotOn/ProtocolHandler.pm</files>
  <action>
Fix the explodePlaylist consumer site (line 656) in ProtocolHandler.pm.

Before the existing guard line that checks $plItem->{track} and $plItem->{track}{id}, call the Plugin helper to normalize the item. Use the established cross-module call pattern already present in this file (Plugins::SpotOn::Plugin::_getAccountId at line 635).

Insert normalization call: Plugins::SpotOn::Plugin::_normalizeLibraryItem($plItem, 'track') right after the loop's item assignment but before the $plItem->{track} access. The existing "require Plugins::SpotOn::Plugin" is already present earlier in this function scope (line 634), so no additional require is needed.

The line structure becomes: iterate items, normalize each, then the existing guard checks $plItem->{track} and $plItem->{track}{id} as before.
  </action>
  <verify>
    <automated>cd /home/sti/spoton && prove t/05_perl_syntax.t 2>&amp;1 | tail -10 &amp;&amp; grep -c '_normalizeLibraryItem' Plugins/SpotOn/ProtocolHandler.pm</automated>
  </verify>
  <done>
    - explodePlaylist normalizes items before checking track key
    - Perl syntax check passes
    - Cross-module call follows established codebase pattern
  </done>
</task>

</tasks>

<verification>
1. Syntax check via test harness: prove t/05_perl_syntax.t
2. Helper is referenced at all 8 consumer sites: grep -n '_normalizeLibraryItem' Plugins/SpotOn/Plugin.pm Plugins/SpotOn/ProtocolHandler.pm should show 9+ hits (1 definition + 7 Plugin.pm call sites + 1 ProtocolHandler.pm call site)
3. Existing test suite passes: cd /home/sti/spoton && prove t/
</verification>

<success_criteria>
- Both Extended Quota ({track: {...}}) and Dev Mode ({item: {...}, track: true}) schemas produce identical behavior
- All 8 consumer sites normalize before accessing type-specific data
- Album and show feeds also handle the Dev Mode schema defensively
- No changes to Client.pm _transformPlaylistContents (Pathfinder path)
- Existing tests pass
</success_criteria>

<output>
Create `.planning/quick/260718-rpy-dev-mode-playlist-schema-fix/260718-rpy-SUMMARY.md` when done
</output>

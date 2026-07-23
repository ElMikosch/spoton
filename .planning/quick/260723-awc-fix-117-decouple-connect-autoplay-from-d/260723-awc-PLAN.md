---
phase: quick
plan: 260723-awc
type: execute
wave: 1
depends_on: []
files_modified:
  - Plugins/SpotOn/Settings/Player.pm
  - Plugins/SpotOn/Unified/DaemonManager.pm
  - Plugins/SpotOn/Plugin.pm
  - Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html
  - Plugins/SpotOn/strings.txt
autonomous: true
requirements: ["GH-117"]
must_haves:
  truths:
    - "enableAutoplay pref controls ONLY the librespot --autoplay flag, never writes to plugin.dontstopthemusic namespace"
    - "Saving SpotOn Player Settings does not overwrite a user's chosen DSTM provider (LastMix, MusicIP, Random Mix, etc.)"
    - "DaemonManager watchdog loop does not auto-claim DSTM provider for any player"
    - "DSTM handler registration in Plugin.pm remains intact so SpotOn appears in the LMS DSTM dropdown"
    - "Player Settings page shows current DSTM provider status as read-only info"
  artifacts:
    - Plugins/SpotOn/Settings/Player.pm
    - Plugins/SpotOn/Unified/DaemonManager.pm
    - Plugins/SpotOn/Plugin.pm
    - Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html
    - Plugins/SpotOn/strings.txt
  key_links:
    - "Player.pm handler() -> only reads DSTM provider for display, never writes"
    - "DaemonManager initHelpers() -> no DSTM auto-configure block"
---

<objective>
Fix GH #117: Decouple Connect Autoplay from DSTM provider.

SpotOn currently conflates Spotify Connect autoplay (librespot --autoplay flag) with LMS
Don't Stop The Music provider selection. This causes SpotOn to silently overwrite user-chosen
DSTM providers (LastMix, MusicIP, Random Mix) and auto-claim all players within 60 seconds.
No other LMS plugin (Spotty, Qobuz, TIDAL) does this.

Purpose: Stop writing to the plugin.dontstopthemusic namespace entirely. Let users pick their
DSTM provider in the standard LMS player settings dropdown. Show a read-only DSTM status hint
in SpotOn Player Settings so users know where to configure it.

Output: Five modified files with DSTM write paths removed, template updated, strings updated.
</objective>

<execution_context>
@/home/sti/.claude/gsd-core/workflows/execute-plan.md
@/home/sti/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@/home/sti/spoton/CLAUDE.md
@/home/sti/spoton/Plugins/SpotOn/Settings/Player.pm
@/home/sti/spoton/Plugins/SpotOn/Unified/DaemonManager.pm
@/home/sti/spoton/Plugins/SpotOn/Plugin.pm
@/home/sti/spoton/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html
@/home/sti/spoton/Plugins/SpotOn/strings.txt
</context>

<tasks>

<task type="auto">
  <name>Task 1: Remove DSTM write paths from Perl backend</name>
  <files>
    Plugins/SpotOn/Settings/Player.pm,
    Plugins/SpotOn/Unified/DaemonManager.pm,
    Plugins/SpotOn/Plugin.pm
  </files>
  <action>
  **Settings/Player.pm — handler() save block (lines 68-75):**
  Delete the entire DSTM provider write block that runs on save. This is the block starting with
  `if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') )` that
  sets `dstmPrefs->client($client)->set('provider', ...)`. The enableAutoplay pref save on
  lines 65-66 stays — it now controls only the librespot --autoplay daemon flag.

  **Settings/Player.pm — handler() readback block (lines 96-101):**
  Delete the block that derives autoplayEnabled from the DSTM provider readback. This is the
  `if ( defined $rawAutoplay && $paramRef->{canAutoplay} && ... )` block that reads
  `dstmPrefs->client($client)->get('provider')` and overrides autoplayEnabled based on whether
  the DSTM provider matches PLUGIN_SPOTON_RECOMMENDATIONS. The value from the SpotOn pref
  (`$rawAutoplay // 1`) is the correct source of truth for the checkbox.

  **Settings/Player.pm — handler() readback: add DSTM status pass-through:**
  After the existing `$paramRef->{autoplayEnabled}` line (which now just does `$rawAutoplay // 1`),
  add a new block that reads the current DSTM provider for display purposes only (read, never write).
  If DontStopTheMusic plugin is enabled, read `dstmPrefs->client($client)->get('provider')`.
  Pass two template variables:
  - `$paramRef->{dstmProvider}` = raw provider string (e.g. 'PLUGIN_SPOTON_RECOMMENDATIONS', '', '0', or another plugin's provider key)
  - `$paramRef->{dstmIsSpotOn}` = 1 if provider eq 'PLUGIN_SPOTON_RECOMMENDATIONS', 0 otherwise
  If DontStopTheMusic plugin is not enabled, set dstmProvider to '' and dstmIsSpotOn to 0.

  **DaemonManager.pm — initHelpers() auto-configure block (lines 312-326):**
  Delete the entire block that starts with the comment "Ensure DSTM provider is set for players
  that never opened SpotOn settings" and ends before the "60s watchdog" comment on line 328.
  This removes the 60-second loop that auto-claims DSTM provider for all players.

  **Plugin.pm — line 116 comment update only:**
  Change the comment on the enableAutoplay default from
  `# D-08: Autoplay toggle, default on (controls Connect autoplay + DSTM)` to
  `# D-08: Autoplay toggle, default on (Connect autoplay only — DSTM decoupled per GH #117)`.
  Do NOT change the default value (1) or the DSTM handler registration on lines 184-190.
  </action>
  <verify>
    <automated>cd /home/sti/spoton && grep -c 'dontstopthemusic' Plugins/SpotOn/Settings/Player.pm | grep -q '^1$' && grep -c 'dontstopthemusic' Plugins/SpotOn/Unified/DaemonManager.pm | grep -q '^0$' && grep 'GH #117' Plugins/SpotOn/Plugin.pm | grep -q 'decoupled' && echo "PASS" || echo "FAIL"</automated>
  </verify>
  <done>
  - Player.pm: no DSTM provider write on save (zero calls to dstmPrefs->set)
  - Player.pm: autoplayEnabled derived from SpotOn pref only, not from DSTM readback
  - Player.pm: dstmProvider and dstmIsSpotOn passed to template as read-only display data
  - Player.pm: exactly one remaining dontstopthemusic reference (the read-only status block)
  - DaemonManager.pm: zero references to dontstopthemusic or DSTM
  - Plugin.pm: comment updated, DSTM handler registration unchanged
  </done>
</task>

<task type="auto">
  <name>Task 2: Update template and i18n strings for Connect-only autoplay</name>
  <files>
    Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html,
    Plugins/SpotOn/strings.txt
  </files>
  <action>
  **player.html — autoplay section (lines 24-31):**
  Keep the existing autoplay checkbox structure intact (the IF canAutoplay guard, the WRAPPER,
  the checkbox input, the label). No changes needed to the checkbox itself since enableAutoplay
  now correctly means Connect autoplay only.

  After the closing label tag (line 29) and before the `[% END %]` on line 30, add a DSTM
  status info block. Use a div with a muted/info style (e.g. `style="margin-top:8px; color:#666; font-size:0.9em"`).
  Show the current DSTM provider status:
  - If dstmIsSpotOn is true: display the PLUGIN_SPOTON_DSTM_STATUS_ACTIVE string
  - Else: display the PLUGIN_SPOTON_DSTM_STATUS_HINT string
  Use `[% IF dstmIsSpotOn %]` / `[% ELSE %]` / `[% END %]` Template Toolkit syntax.

  **strings.txt — update PLUGIN_SPOTON_AUTOPLAY_ENABLED_DESC (lines 1132-1143):**
  Replace all 12 language translations. The new description should convey that this controls
  Spotify Connect autoplay only (when a playlist or album ends, Spotify continues with similar
  tracks). Do not mention DSTM or Browse. English example:
  "When enabled, Spotify continues playing similar tracks after a playlist or album ends (Connect mode). This does not affect Don't Stop The Music — configure that in LMS Player Settings."

  Keep translations concise. For languages other than EN and DE, use English as the translation
  (this matches the existing pattern in the codebase where non-core languages sometimes use EN).

  **strings.txt — add two new string blocks after PLUGIN_SPOTON_AUTOPLAY_ENABLED_LABEL (after line 1156):**

  PLUGIN_SPOTON_DSTM_STATUS_ACTIVE — shown when SpotOn is the selected DSTM provider.
  EN: "Don't Stop The Music: SpotOn is selected as provider (change in LMS Player Settings)"
  DE: "Don't Stop The Music: SpotOn ist als Anbieter ausgewaehlt (aendern in LMS Player-Einstellungen)"
  All other languages: use EN text.

  PLUGIN_SPOTON_DSTM_STATUS_HINT — shown when SpotOn is NOT the DSTM provider (or DSTM disabled).
  EN: "Don't Stop The Music: To use SpotOn recommendations after Browse playlists end, select SpotOn in LMS Player Settings > Don't Stop The Music."
  DE: "Don't Stop The Music: Um SpotOn-Empfehlungen nach Ende von Browse-Playlists zu nutzen, waehle SpotOn in LMS Player-Einstellungen > Don't Stop The Music."
  All other languages: use EN text.
  </action>
  <verify>
    <automated>cd /home/sti/spoton && grep -q 'PLUGIN_SPOTON_DSTM_STATUS_ACTIVE' Plugins/SpotOn/strings.txt && grep -q 'PLUGIN_SPOTON_DSTM_STATUS_HINT' Plugins/SpotOn/strings.txt && grep -q 'dstmIsSpotOn' Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html && echo "PASS" || echo "FAIL"</automated>
  </verify>
  <done>
  - player.html shows read-only DSTM status info below the autoplay checkbox
  - PLUGIN_SPOTON_AUTOPLAY_ENABLED_DESC updated to Connect-only wording in all 12 languages
  - Two new string blocks added: DSTM_STATUS_ACTIVE and DSTM_STATUS_HINT with all 12 languages
  - No DSTM write controls in the template (no form inputs that write to dontstopthemusic)
  </done>
</task>

</tasks>

<verification>
1. `grep -c 'dstmPrefs.*->set' Plugins/SpotOn/Settings/Player.pm` returns 0 (no DSTM writes on save)
2. `grep -c 'dontstopthemusic' Plugins/SpotOn/Unified/DaemonManager.pm` returns 0 (auto-configure removed)
3. `grep -c 'dontstopthemusic' Plugins/SpotOn/Settings/Player.pm` returns 1 (read-only status block only)
4. `grep 'DontStopTheMusic' Plugins/SpotOn/Plugin.pm` still shows handler registration (lines 184-190 intact)
5. `perl -c Plugins/SpotOn/Settings/Player.pm` compiles without errors (run from repo root with proper @INC)
6. `grep -c 'PLUGIN_SPOTON_DSTM_STATUS' Plugins/SpotOn/strings.txt` returns 24 (2 keys x 12 languages)
</verification>

<success_criteria>
- enableAutoplay pref is fully decoupled from DSTM: toggling autoplay in SpotOn Player Settings
  only affects the librespot --autoplay daemon flag
- User's existing DSTM provider choice (LastMix, MusicIP, Random Mix, or SpotOn) is never
  overwritten by SpotOn save or watchdog
- SpotOn Player Settings shows current DSTM status as informational text with pointer to LMS
  Player Settings for changing it
- SpotOn still appears in the LMS DSTM dropdown (handler registration preserved)
- All files compile/parse without errors
</success_criteria>

<output>
Create `.planning/quick/260723-awc-fix-117-decouple-connect-autoplay-from-d/260723-awc-SUMMARY.md` when done
</output>

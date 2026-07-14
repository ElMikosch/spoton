# Roadmap: SpotOn

**Project:** SpotOn — LMS Spotify Plugin
**Created:** 2026-05-26
**Granularity:** standard

## Milestones

- ✅ **v1.0 Foundation** — Phases 1-6 (shipped 2026-06-03)
- ✅ **v1.1 Hardening & Reach** — Phases 7-12 (shipped 2026-06-06)
- ✅ **v1.3 Polish & Publish** — Phases 13-16.1 (shipped 2026-06-13)
- ✅ **v1.5 Podcasts** — Phases 18-21 (shipped 2026-06-15)
- 🔄 **v2.0 Browse Daemon Migration** — Phases 28-30 (active)

## Phases

<details>
<summary>✅ v1.0 Foundation (Phases 1-6) — SHIPPED 2026-06-03</summary>

- [x] **Phase 1: Plugin Skeleton + Binary Foundation** — completed 2026-05-26
- [x] **Phase 2: Auth + API Foundation** (6/6 plans) — completed 2026-05-27
- [x] **Phase 02.1: OAuth-PKCE Browser Auth** (4/4 plans) — completed 2026-05-27
- [x] **Phase 3: Browse + Navigation** (3/3 plans) — completed 2026-05-28
- [x] **Phase 4: Single-Track Streaming** (2/2 plans) — completed 2026-05-28
- [x] **Phase 04.1: Streaming Bug Fixes + Passthrough Binary** (2/2 plans) — completed 2026-05-28
- [x] **Phase 04.2: Credentials + Made For You Fix** (2/2 plans) — completed 2026-05-29
- [x] **Phase 04.3: ZeroConf + Keymaster Auth** (4/4 plans) — completed 2026-05-29
- [x] **Phase 04.4: Dual-Token API Routing** (2/2 plans) — completed 2026-05-29
- [x] **Phase 5: Spotify Connect** (5/5 plans) — completed 2026-06-01
- [x] **Phase 05.1: Connect Audio Streaming Bugfix** (3/3 plans) — completed 2026-06-01
- [x] **Phase 05.2: Connect Controls & Resume** (2/2 plans) — completed 2026-06-01
- [x] **Phase 05.3: Sync Groups + Connect Robustness** (3/3 plans) — completed 2026-06-02
- [x] **Phase 05.4: mDNS Connect Discovery Fix** (3/3 plans) — completed 2026-06-02
- [x] **Phase 6: Polish + DSTM + Settings** (5/5 plans) — completed 2026-06-03

</details>

<details>
<summary>✅ v1.1 Hardening & Reach (Phases 7-12) — SHIPPED 2026-06-06</summary>

- [x] **Phase 7: DE→EN Code Cleanup** (1/1 plan) — completed 2026-06-03
- [x] **Phase 8: Multi-Arch Binary Distribution** (2/2 plans) — completed 2026-06-03
- [x] **Phase 9: Stream Metadata** (1/1 plan) — completed 2026-06-04
- [x] **Phase 9.5: Prod Deployment & Monitoring** (2/2 plans) — completed 2026-06-04
- [x] **Phase 10: Connect-DSTM** (3/3 plans) — completed 2026-06-04
- [x] **Phase 11: Track History Metadata** (2/2 plans) — completed 2026-06-05
- [x] **Phase 12: Protocol Handler Rename** (2/2 plans) — completed 2026-06-05

</details>

<details>
<summary>✅ v1.3 Polish & Publish (Phases 13-16.1) — SHIPPED 2026-06-13</summary>

- [x] **Phase 13: Repo Maintenance** (2/2 plans) — completed 2026-06-07
- [x] **Phase 14: Connect Fixes** (2/2 plans) — completed 2026-06-07
- [x] **Phase 15: Like Button** (2/2 plans) — completed 2026-06-11
- [x] **Phase 16: macOS Universal Binary** (2/2 plans) — completed 2026-06-11
- [x] **Phase 16.1: CI Conditional Build** (1/1 plan) — completed 2026-06-12

</details>

- ✅ **v1.5 Podcasts** — Phases 18-21 (shipped 2026-06-15) → [archive](milestones/v1.5-ROADMAP.md)

## Active

- [x] **Phase 22: Seek + Favorites Bugfixes** — completed 2026-06-17
  **Goal**: Fix seeking (duration 0:00 in seek bar) and LMS favorites (spotify: scheme statt spoton://)
  **Plans:** 1 plan

  Plans:

  - [x] 22-01-PLAN.md — Fix seek bar duration + favorites URL scheme + explodePlaylist

- [ ] **Phase 23: Forum Monitor + Draft Generation**
  **Goal**: GitHub Action (cron) die den Lyrion-Forum-Thread pollt, neue Posts erkennt, via Claude API Draft-Replies generiert und als GitHub Issues zur Review erstellt.

- [ ] **Phase 24: Forum Auto-Post**
  **Goal**: Label-getriggerter GitHub Action Workflow der approved Draft-Replies automatisch im vBulletin-Forum postet.

- [x] **Phase 25: Play-All Full Pagination** — completed 2026-06-18
  **Goal**: Play-All auf Playlists, Liked Songs, Alben und Shows spielt alle Tracks ab — nicht nur die erste API-Seite (max 50/100). Reusable Paginator-Helper für alle Feed-Funktionen.
  **Plans:** 1/1 plans complete

  Plans:

  - [x] 25-01-PLAN.md — Reusable _fetchAllPages helper + integration in all four feeds + ProtocolHandler show-explode fix

- [x] **Phase 26: Browse Error Recovery + Diagnostics** — completed 2026-06-21
  **Goal**: Unavailable Tracks in Browse Mode erkennen und automatisch skippen statt endlos hängen. Diagnostic Bundle um Browse-Mode stderr erweitern.
  **Plans:** 2/2 plans complete

  Plans:

  - [x] 26-01-PLAN.md — Unavailable track detection + auto-skip
  - [x] 26-02-PLAN.md — Browse stderr capture for diagnostics

- [x] **Phase 27: Browse Pipeline Failure Recovery** — completed 2026-06-22
  **Goal**: Prefetch-Hang bei unavailable Tracks verhindern (LMS wartet auf PCM-Daten die nie kommen) und Rapid-Retry-Loop stoppen.
  **Plans:** 1/1 plans complete

  Plans:

  - [x] 27-01-PLAN.md — Prefetch watchdog + skip cache

### v2.0 Browse Daemon Migration

- [x] **Phase 28: Persistent Browse Daemon** — completed 2026-06-22
  **Goal**: Per-track `--single-track` spawning durch persistenten Browse-Daemon mit HTTP-Track-Serving ersetzen. Löst Prefetch-Hang, Audio-Key-Throttling und Log-Flood an der Wurzel.
  **Plans:** 3/3 plans complete
  Canonical refs: `.planning/notes/browse-daemon-architecture-decision.md`

  Plans:

  - [x] 28-01-PLAN.md — Browse daemon Rust implementation (HTTP server + track endpoint)
  - [x] 28-02-PLAN.md — Browse daemon lifecycle modules (DaemonManager + Daemon Perl)
  - [x] 28-03-PLAN.md — Browse-HTTP pipeline integration (ProtocolHandler + Plugin wiring)

- [x] **Phase 29: Unified Browse+Connect Daemon** (completed 2026-06-22)
  **Goal**: Browse- und Connect-Daemon in einen Prozess pro Player zusammenführen — ein librespot-Prozess mit Spirc (Connect) + HTTP Track-Endpoint (Browse) gleichzeitig. Eliminiert doppelten RAM-Overhead und Session-Koordination.
  **Plans:** 3 plans
  Canonical refs: `.planning/notes/browse-daemon-architecture-decision.md`, `.planning/seeds/evaluate-phase2-unified-daemon.md`

  Plans:

  - [x] 29-01-PLAN.md — Unified Rust daemon (unified.rs + main.rs CLI dispatch)
  - [x] 29-02-PLAN.md — Unified Perl DaemonManager + Daemon lifecycle modules
  - [x] 29-03-PLAN.md — Integration (ProtocolHandler + Plugin.pm + daemonMode pref)

- [ ] **Phase 30: Legacy Pipe Cleanup**
  **Goal**: Remove `--single-track` mode and `son-*` transcoding pipelines. Remove `browseMode`/`daemonMode` toggle prefs. Delete Browse::DM, Browse::Daemon, Connect::DM, Connect::Daemon modules. Add rapid-skip debounce to unified.rs.
  **Plans:** 2 plans

  Plans:

  - [x] 30-01-PLAN.md — Delete legacy Perl modules + simplify Plugin.pm/ProtocolHandler.pm/Connect.pm + remove son-* from custom-convert.conf + remove dead Rust modes
  - [ ] 30-02-PLAN.md — Add browse_abort_gen rapid-skip debounce to unified.rs + final verification

### v3.0 Auth Overhaul

### Phase 49: PKCE OAuth Flow

- [x] **Phase 49: PKCE OAuth Flow** (completed 2026-07-14)
  **Goal**: Implement PKCE OAuth authorization flow — GitHub Pages static relay, LMS Settings handler for code_verifier, token exchange, refresh token storage. AUTH-01, AUTH-02.
  **Plans:** 2/2 plans complete
  Depends on: Keymaster audit (.planning/notes/keymaster-audit.md), spike findings (spike-findings-spoton skill), urknall edge cases (#176)

  Plans:

  - [x] 49-01-PLAN.md — PKCE core module (crypto, token exchange, persistence) + GitHub Pages relay page
  - [x] 49-02-PLAN.md — Settings integration (PKCE handlers, auth UI, copy-paste fallback, i18n strings)

### Phase 50: Perl TokenManager Rewrite

- [ ] **Phase 50: Perl TokenManager Rewrite**
  **Goal**: Replace Keymaster-based TokenManager with PKCE token management — refresh flow, expiry handling, per-player token isolation. AUTH-05.
  Depends on: Phase 49

### Phase 51: Credential Derivation + Connect

- [ ] **Phase 51: Credential Derivation + Connect**
  **Goal**: Convert PKCE access tokens to stored credentials for librespot Connect sessions. Ensure Connect registration and audio playback work with PKCE-derived credentials. AUTH-03, AUTH-04.
  Depends on: Phase 50

### Phase 52: sp_dc + Pathfinder Integration

- [ ] **Phase 52: sp_dc + Pathfinder Integration**
  **Goal**: Best-effort sp_dc cookie extraction + Pathfinder API for Made for You content. TOTP rotation, graceful degradation, re-scrape on failure.
  Depends on: Phase 50

### Phase 53: Keymaster Removal + Migration

- [ ] **Phase 53: Keymaster Removal + Migration**
  **Goal**: Remove all hm://keymaster/token/authenticated code paths. Migration UX for existing ZeroConf users to PKCE. UAT gate: no Keymaster service calls in normal logs. AUTH-06, AUTH-07.
  Depends on: Phase 49, Phase 50, Phase 51

## Progress Table

| Phase | Milestone | Plans | Status | Completed |
|-------|-----------|-------|--------|-----------|
| 1-6 (15 phases) | v1.0 | 50/50 | Complete | 2026-06-03 |
| 7-12 (7 phases) | v1.1 | 13/13 | Complete | 2026-06-06 |
| 13-16.1 (5 phases) | v1.3 | 9/9 | Complete | 2026-06-13 |
| 18. Podcast API Foundation | v1.5 | 1/1 | Complete | 2026-06-14 |
| 19. Podcast Browse | v1.5 | 2/2 | Complete | 2026-06-14 |
| 20. Podcast Library Actions | v1.5 | 1/1 | Complete | 2026-06-15 |
| 21. Podcast UX Polish + i18n | v1.5 | 2/2 | Complete | 2026-06-15 |
| 22. Seek + Favorites Bugfixes | — | 1/1 | Complete | 2026-06-17 |
| 25. Play-All Full Pagination | — | 1/1 | Complete | 2026-06-18 |
| 26. Browse Error Recovery | — | 2/2 | Complete | 2026-06-21 |
| 27. Pipeline Failure Recovery | — | 1/1 | Complete | 2026-06-22 |
| 28. Persistent Browse Daemon | v2.0 | 3/3 | Complete | 2026-06-22 |
| 29. Unified Daemon | v2.0 | 3/3 | Complete   | 2026-06-22 |
| 30. Legacy Pipe Cleanup | v2.0 | 1/2 | In Progress|  |

## Backlog

Items discovered during development — not assigned to a milestone.

1. **Eigene SpotOn Client-ID bei Spotify registrieren** — Blocked: Spotify requires 250k MAU + legally registered business. Extended Quota documentation deferred to future milestone.
2. **~~Online-Musiksammlung (Importer.pm / OnlineLibraryBase)~~** — Evaluiert und bewusst abgelehnt. API-Quota im Dev Mode macht Library-Scan extrem teuer; Browse > Library deckt den Use Case on-demand ab.
3. ~~**LMS Community Repo Submission**~~ — Erledigt: Plugin im Community Repo veröffentlicht.
4. ~~**ZeroConf Auth UX: "Connected" an Spotify App melden**~~ — Verworfen: Setup Guide erklärt das Verhalten, kein technischer Fix möglich ohne Playback-Session.
5. ~~**Diagnostics: "Clear Logs" Button in Settings**~~ — Implementiert in v1.7.4 (truncate on daemon restart + Clear Logs button).
6. **Spotty Favorites Migration** — Settings-Button der `spotify://` Einträge in LMS Favorites und Playlists als `spoton://` Duplikate anlegt. Originale bleiben erhalten, User kann Spotty danach deinstallieren. URI-Schema nach Prefix ist identisch (`track:ID`, `album:ID`, etc.). Idee von Paul Webster (Forum #32, 2026-06-19).

---
*Roadmap created: 2026-05-26*
*Last updated: 2026-06-22 — Phase 30 plans created (2 plans, 2 waves)*

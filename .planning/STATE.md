---
gsd_state_version: 1.0
milestone: v2.3
milestone_name: Library Integration
status: ready_to_plan
stopped_at: v2.3.14 released, auth research done
last_updated: 2026-07-09
last_activity: 2026-07-09 -- Quick task: diagnostics + daemon stability (browse-errors.log cleanup, token status in diag, port timeout 10s, staggered start)
progress:
  total_phases: 5
  completed_phases: 0
  total_plans: 1
  completed_plans: 1
  percent: 0
---

# Project State: SpotOn

**Project:** SpotOn — LMS Spotify Plugin
**Initialized:** 2026-05-26
**Mode:** yolo

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-30)

**Core Value:** Reliable Spotify playback and Connect integration on LMS — Browse, stream, and control via Spotify app, without 429 bursts, zombie daemons, or audio glitches.

**Current Focus:** v3.0 Auth Overhaul — spike session complete, urknall #176 feedback incorporated, ready for Phase 49-00

## Current Position

Phase: 48 SUPERSEDED → v3.0 planned (Phases 49-53)
Plan: Spike findings packaged, phases defined, branch pending
Status: Ready to create v3.0-auth branch and plan Phase 49-00 (Token Usage Audit)
Last activity: 2026-07-05

## Progress Bar

```
v2.3 Library Integration: [░░░░░░░░░░░░░░░░░░░░] 0/5 phases (37-41)
Phase 37: [x] Context Menu LMS Items (CTX-01)
Phase 38: [ ] Importer Foundation (LIB-06, TOK-01, TOK-02, CFG-01)
Phase 39: [ ] Album + Artist Import (LIB-02, LIB-03, LIB-07, LIB-09)
Phase 40: [ ] Liked Songs + Incremental Sync (LIB-01, LIB-04, LIB-05, LIB-08)
Phase 41: [ ] Playlist Import (PL-01, PL-02, CFG-02)

Side phases (independent):
Phase 42: [x] OGG Vorbis Passthrough (OGG-01..03)
Phase 43: [x] Connect OGG Passthrough (OGG-04)
Phase 44: [x] Connect OGG Rate-Limiting (OGG-05)
Phase 46: [x] Code Review Bugfixes (30 findings)
Phase 48: [~] SUPERSEDED by v3.0 Auth Overhaul (2026-07-04)

v3.0 Auth Overhaul (Phases 49-53, branch: v3.0-auth):
Phase 49-00: [ ] Token Usage Audit + Backend Evaluation
Phase 49: [ ] PKCE OAuth Flow (AUTH-01, AUTH-02)
Phase 50: [ ] Perl TokenManager Rewrite (AUTH-03)
Phase 51: [ ] Credential Derivation + Connect (AUTH-04, AUTH-05)
Phase 52: [ ] sp_dc + Pathfinder Integration (Made for You)
Phase 53: [ ] Keymaster Removal + Migration (AUTH-06, AUTH-07)
```

## Performance Metrics

**Historical velocity (reference):**

- v2.0: 9 phases, 16 plans in 9 days (~1.8 plans/day)
- v2.1: 2 phases, 2 plans in 1 day
- v1.5: 4 phases, 6 plans in 2 days (~3 plans/day)
- v1.0: 15 phases, 50 plans in 9 days (~5-6 plans/day)

## Deferred Items

Items carried forward from previous milestones:

| Category | Item | Status |
|----------|------|--------|
| debug | connect-reconnect-no-audio | awaiting_human_verify |
| uat | Phase 16 macOS Binary (3 scenarios) | deferred (no macOS test env) |

## Accumulated Context

### Decisions

- [v2.3]: Importer follows OnlineLibraryBase pattern (Spotty, Qobuz, TIDAL, Deezer)
- [v2.3]: me/tracks returns full objects — no individual entity fetches needed
- [v2.3]: Incremental sync via added_at early-exit (Spotty doesn't have this)
- [v2.3]: Scanner uses SimpleSyncHTTP (blocking OK in scanner process)
- [v2.3]: Token routing: Own ID via Keymaster, fallback to bundled on 403
- [v2.3]: PKCE-only is the Golden Path — replaces ZeroConf/Keymaster as single auth mechanism
- [v2.3]: ~~Phase 48 is a bridge (login5 fallback), not the target architecture~~ SUPERSEDED → v3.0
- [v2.3]: Keymaster is dying — 403s widespread since Aug 2025
- [v2.3]: login5 rejects Developer App IDs — Dual-Token architecture is dead
- [v3.0]: Auth Overhaul — PKCE + sp_dc/Pathfinder. 7 spikes validated 2026-07-04. Phase 48 archived.
- [v3.0]: PKCE-first confirmed as correct direction (urknall agrees given Extended Quota Client ID)
- [v3.0]: ZeroConf stays as feature (mDNS guest-discovery), no longer an auth mechanism
- [v3.0]: Discovery ON by default — --disable-discovery is per-player option, not default
- [v3.0]: Callback URI via GitHub Pages static relay (stiefenm.github.io/spoton/auth/), state parameter with LMS callback URL + nonce
- [v3.0]: Login5 fallback declined (Login5 gets immediate 429 on api.spotify.com)
- [v3.0]: Desktop Client ID OAuth declined (ToS risk, unnecessary with Extended Quota)
- [v3.0]: go-librespot = token/control reference only, NOT audio backend replacement (Rust librespot stays for OGG passthrough, Connect sinks, rate-limiting — go-librespot lacks these)
- [v3.0]: Keymaster audit must distinguish 4 buckets: (1) Real Keymaster Service (hm://keymaster/token/authenticated), (2) Old Keymaster Client-ID used as platform identity hint, (3) Login5 path, (4) PKCE path
- [v3.0]: UAT gate is specifically "hm://keymaster/token/authenticated must NOT appear in normal logs" — not "string Keymaster appears anywhere" (client-ID-as-identity references are fine to keep)
- [v3.0]: Login5 already used by Rust librespot internally for spclient HTTP (not just session bootstrap) — supports our architecture where librespot handles its own session auth
- [v3.0]: OAuth-token-authenticated sessions cannot use Keymaster service (confirms credential derivation approach is correct — PKCE tokens must be converted to stored credentials for Connect)
- [v3.0]: 7 PKCE implementation edge cases (urknall #176): (A) code_verifier must never appear on GitHub Pages — stays in LMS Settings handler only, (B) static relay uses window.location navigation not fetch — CORS-safe, (C) callback redirect target restricted to RFC1918/loopback/.local addresses, (D) copy-paste fallback when redirect fails, (E) v2/PKCE account mismatch detection needed (existing ZeroConf creds from different account than PKCE login), (F) guest ZeroConf must not overwrite primary PKCE-derived credentials, (G) refresh-token expiry (6 months inactivity) needs first-class UX with re-auth prompt
- [v3.0]: sp_dc/Pathfinder as "best effort" — TOTP rotation, graceful degradation, re-scrape on failure
- [v3.0]: urknall's 11 success criteria as UAT gates (central: no hm://keymaster/token/authenticated in normal logs)
- [v3.0]: Audit phase (49-00) before implementation — classify every Keymaster reference into the 4 buckets

### Blockers/Concerns

- Forum #143 (plasticator2): Audio distortion on Pi 4B + HiFiBerry Digi2 Pro SPDIF — log analysis pending
- ~~PR #104 (urknall): Release year metadata — review pending~~ MERGED, shipped in v2.3.8
- Forum #159 (Chezza): New Spotify account (Oct 2025) → NoStoredCredentials, urknall + CJS helping
- ~~Forum #160 (CJS): "Default Adjustment for Remote Streams" stacks with SpotOn ReplayGain~~ FIXED in v2.3.12: trackGain() implemented (GH #108)
- ~~Wait for urknall's response to auth architecture reply (#175)~~ RESOLVED: urknall #176 confirmed PKCE-first, provided edge cases and Keymaster audit guidance
- Auth architecture research completed — details in private notes (SynologyDrive), not in this repo.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260709-bsx | Diagnostik + Daemon-Stabilität Verbesserungen | 2026-07-09 | e714019 | [260709-bsx](./quick/260709-bsx-diagnostik-daemon-stabilitaet-verbesseru/) |

## Session Continuity

**Last session:** 2026-07-09
**Stopped at:** v2.3.17 released, #99 reopened + fix shipped, #116 OGG hypothesis replied
**Next action (in order):**
1. Create v3.0-auth branch from main
2. `/gsd-plan-phase 49-00` (Token Usage Audit)

---
*State initialized: 2026-05-26*
*Last updated: 2026-07-09 — v2.3.17 released (#99 fix), #116 + #99 replied*

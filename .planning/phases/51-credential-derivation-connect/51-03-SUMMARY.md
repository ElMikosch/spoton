---
phase: 51-credential-derivation-connect
plan: 03
subsystem: auth
tags: [perl, oauth, pkce, settings-ui, i18n, lms-plugin, spotify-connect]

# Dependency graph
requires:
  - phase: 51-credential-derivation-connect (plan 01)
    provides: "Plugins::SpotOn::API::Credentials — deriveCredentials, credentialsPathFor, verifyCredentials, accountMismatch, isCredentialError"
  - phase: 51-credential-derivation-connect (plan 02)
    provides: "DaemonManager lazy-derivation safety net + D-08 mismatch repair (the eager Settings path is a distinct, earlier-firing trigger for the same Credentials.pm module)"
provides:
  - "Settings.pm _pkceStoreAccount eager derivation call site (D-01) — every fresh PKCE auth immediately derives credentials.json while the token is guaranteed fresh"
  - "D-06 unconditional DaemonManager->scheduleInit on derivation success — Connect device appears without waiting for the 60s watchdog, for first-account, additional-account, and re-auth flows alike (closes Pitfall 6)"
  - "D-02 non-blocking failure UX — PLUGIN_SPOTON_CONNECT_DERIVE_FAILED warning string (11 languages) rendered on derivation failure without rolling back account creation"
  - "Unified success signal — PLUGIN_SPOTON_PKCE_SUCCESS now fires only after derivation completes (Open Question 2 resolution)"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Eager-derivation-at-auth-completion: nest deriveCredentials inside the existing _storeAccountPrefs success callback rather than adding a second async round-trip"
    - "connectReady (0/1) + optional warning field in the PKCE JSON response contract, giving the basic.html AJAX flow a machine-readable derivation-success signal alongside the human-readable string"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Settings.pm
    - Plugins/SpotOn/strings.txt
    - t/02_strings.t
    - t/09_settings.t

key-decisions:
  - "D-06 daemon start is unconditional on derivation success, deliberately bypassing _storeAccountPrefs's own $needsDaemonStart conditional (which only fires for the very first account ever configured) -- required to close the Pitfall 6 gap for 'Add Another Account' and re-auth flows"
  - "Failure branch never reflects the raw derivation $reason into the user-facing page (T-51-10) -- only the fixed PLUGIN_SPOTON_CONNECT_DERIVE_FAILED i18n string is rendered; the log line uses a masked accountId"
  - "Success messaging is deferred until after derivation completes rather than split into a two-step narration (OAuth-connected, then Connect-ready) -- one unified signal per D-02"

requirements-completed: [AUTH-03]

coverage:
  - id: D1
    description: "PKCE auth completion in Settings eagerly derives librespot credentials.json via Credentials->deriveCredentials, called from inside _pkceStoreAccount's _storeAccountPrefs success callback"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/09_settings.t#Plan51-03: _pkceStoreAccount calls deriveCredentials exactly once on success"
        status: pass
    human_judgment: false
  - id: D2
    description: "Daemon start triggers unconditionally on derivation success (D-06), regardless of whether an account was already active -- closes the Pitfall 6 gap for Add Another Account / re-auth flows that the first-account-only $needsDaemonStart conditional misses"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/09_settings.t#Plan51-03 Pitfall 6: scheduleInit fires unconditionally even though activeAccount was already set"
        status: pass
    human_judgment: false
  - id: D3
    description: "Derivation failure does not block or roll back account creation, and does not trigger scheduleInit; tokens remain stored so Browse/Search keep working via Phase 50's PKCE tokens (D-02)"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/09_settings.t#Plan51-03 D-02: account creation NOT rolled back when derivation fails; Plan51-03 D-06: scheduleInit NOT called when derivation fails"
        status: pass
    human_judgment: false
  - id: D4
    description: "PLUGIN_SPOTON_CONNECT_DERIVE_FAILED i18n warning string exists in all 11 languages with bilingual (EN/DE minimum) test coverage, and the success message now fires only after derivation completes"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/02_strings.t (bilingual_keys), t/09_settings.t (strings.txt block presence + structure assertion on the failure branch)"
        status: pass
    human_judgment: false
  - id: D5
    description: "Manual end-to-end verification: completing a PKCE auth in LMS Settings on the dev machine produces credentials.json within seconds, the success page renders, and the daemon starts without waiting for the 60s watchdog"
    requirement: "AUTH-03"
    verification: []
    human_judgment: true
    rationale: "Requires a live LMS + Settings UI + real Spotify OAuth round-trip; reserved for the phase-level /gsd-verify-work UAT alongside plan 02's Connect end-to-end check, per this plan's own <verification> section."

# Metrics
duration: 13min
completed: 2026-07-14
status: complete
---

# Phase 51 Plan 03: Settings-Eager Credential Derivation Summary

**Wired Plugins::SpotOn::API::Credentials into Settings.pm's _pkceStoreAccount so every fresh PKCE authentication eagerly derives librespot credentials and unconditionally kicks off the daemon — Connect appears without the 60s watchdog delay, and derivation failures only warn, never block account creation.**

## Performance

- **Duration:** ~13 min
- **Started:** 2026-07-14T16:49:24+02:00 (after 51-02 commit)
- **Completed:** 2026-07-14T17:00:17+02:00
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- `_pkceStoreAccount`'s `_storeAccountPrefs` success callback now calls `Plugins::SpotOn::API::Credentials->deriveCredentials` immediately, converting the just-exchanged, guaranteed-fresh PKCE access token into `credentials.json` (D-01).
- On success, `Plugins::SpotOn::Unified::DaemonManager->scheduleInit()` fires unconditionally — closing the RESEARCH Pitfall 6 gap where "Add Another Account" and re-auth flows previously had to wait up to 60s for the watchdog to notice new credentials (D-06). This also covers D-07 via DaemonManager's existing account-change detection.
- On failure, the account is still created (tokens already stored, Browse/Search work via Phase 50's PKCE tokens) and the user sees the new `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED` warning instead of a blocking error (D-02); the raw failure reason is never reflected into the HTML/JSON response (T-51-10), only logged with a masked accountId.
- The `PLUGIN_SPOTON_PKCE_SUCCESS` message now fires only after derivation completes, resolving RESEARCH Open Question 2 (one unified user-facing signal, not a two-step narration).
- New i18n key `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED` added in all 11 languages (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV), with bilingual test coverage in `t/02_strings.t`.
- `t/09_settings.t` gained direct functional coverage of `_pkceStoreAccount` (not just structure/grep assertions): a `FakeSettingsResponse` double plus extended `Credentials`/`DaemonManager`/`TokenManager` stubs exercise the real success and failure paths end-to-end against the stubbed collaborators.
- Full test suite green: 564 tests across 16 files (`prove t/`), no regressions.

## Task Commits

Each task was committed atomically:

1. **Task 1: Settings.pm — eager derivation in _pkceStoreAccount with D-02 feedback and D-06 daemon start** - `f010499` (feat)
2. **Task 2: i18n string (11 languages) + test updates (t/02_strings.t, t/09_settings.t)** - `683a172` (test)

**Plan metadata:** (this commit)

## Files Created/Modified
- `Plugins/SpotOn/Settings.pm` - `_pkceStoreAccount`'s success callback now nests an eager `Credentials->deriveCredentials` call; success branch unconditionally calls `DaemonManager->scheduleInit` and renders `connectReady => 1`; failure branch warns with a masked accountId, renders `connectReady => 0` + the new i18n warning string, and does not block account creation.
- `Plugins/SpotOn/strings.txt` - Added `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED` block (11 languages) directly after `PLUGIN_SPOTON_PKCE_ERROR`.
- `t/02_strings.t` - Added `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED` to `@bilingual_keys`.
- `t/09_settings.t` - Extended `Plugins::SpotOn::API::TokenManager` stub with a minimal `_storeAccountPrefs` re-implementation (account creation + first-account-only `activeAccount` semantics); added new `Plugins::SpotOn::API::Credentials` stub (call-count/last-account recorder) and extended the `DaemonManager` stub with a `scheduleInit` call counter; added a `FakeSettingsResponse` double; added a structure assertion for `deriveCredentials`/`PLUGIN_SPOTON_CONNECT_DERIVE_FAILED`; added a new functional test block exercising `_pkceStoreAccount` directly for both the success and failure paths.

## Decisions Made
- D-06 daemon start is unconditional on derivation success, deliberately bypassing `_storeAccountPrefs`'s own `$needsDaemonStart` conditional (first-account-only) — required to close the Pitfall 6 gap for "Add Another Account" and re-auth flows, which the plan's threat model and acceptance criteria both call out explicitly.
- The failure branch never reflects the raw derivation `$reason` into the user-facing page (T-51-10 mitigation) — only the fixed `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED` string is rendered; the log line uses a masked accountId (`substr($accountId, 0, 4) . '****'`), matching the `_mask` convention already established in `TokenManager.pm`/`Credentials.pm`.
- Success messaging is deferred until after derivation completes rather than split into a two-step narration — resolves RESEARCH Open Question 2 with one unified user-facing signal per D-02.
- The new functional test block in `t/09_settings.t` was placed *after* the existing AUTH-06 (account switch) test rather than immediately following the structure-tests block, because it deliberately mutates the shared `plugin.spoton` prefs `accounts`/`activeAccount` keys via the stubbed `Slim::Utils::Prefs`, which uses `//=` (define-once) semantics in its `init()` — placing it earlier would have silently broken AUTH-06's own `init()`-based setup.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking issue] `Slim::Web::HTTP::addHTTPResponse` not loaded when exercising `_pkceStoreAccount` directly**
- **Found during:** Task 2 (writing the new functional test block)
- **Issue:** Settings.pm calls `Slim::Web::HTTP::addHTTPResponse(...)` as a fully-qualified function without ever `require`-ing the module itself (production relies on LMS having already loaded it). No existing test in `t/09_settings.t` executed a code path that reached this call, so the stub module was never actually loaded, producing "Undefined subroutine &Slim::Web::HTTP::addHTTPResponse".
- **Fix:** Added an explicit `require Slim::Web::HTTP;` at the top of the new SKIP block before invoking `_pkceStoreAccount`.
- **Files modified:** `t/09_settings.t`
- **Verification:** `prove t/09_settings.t` green.
- **Committed in:** `683a172` (part of Task 2 commit)

**2. [Rule 1 - Bug] New functional test block clobbered shared prefs state needed by the pre-existing AUTH-06 test**
- **Found during:** Task 2 (first test run after adding the functional block)
- **Issue:** Placing the new `_pkceStoreAccount` functional test block immediately after the structure-tests SKIP block (before AUTH-06) caused it to populate the shared `plugin.spoton` prefs stub's `accounts`/`activeAccount` keys. AUTH-06's own `$prefs->init({ accounts => {...}, activeAccount => '' })` call only sets values that are still `undef` (define-once semantics matching the stub's `//=` implementation), so it silently no-op'd once those keys were already touched — breaking `switchAccount` validation and failing the existing AUTH-06 assertion.
- **Fix:** Moved the new SKIP block to run *after* the AUTH-06 block instead of before it (no other later test depends on a pristine `accounts`/`activeAccount` state).
- **Files modified:** `t/09_settings.t`
- **Verification:** `prove t/09_settings.t` green (63/63), `prove t/` full suite green (564/564).
- **Committed in:** `683a172` (part of Task 2 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 1/3, test-harness-only — no production code changes beyond what Task 1 already specified).
**Impact on plan:** Both fixes were necessary to make the plan's own required test coverage (Task 2's assertions a/b/c) actually exercise the real `_pkceStoreAccount` code path without breaking existing tests. No scope creep — Settings.pm itself matches Task 1's action/acceptance-criteria exactly.

## Issues Encountered
None beyond the two auto-fixed test-harness issues documented above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The eager (Settings, this plan) and lazy (DaemonManager, plan 02) derivation call sites are both wired; AUTH-03/AUTH-04 credential derivation is now triggered from every angle the phase's RESEARCH document identified (fresh PKCE auth, daemon startup self-heal, crash-loop re-derive).
- Phase-level manual UAT (`/gsd-verify-work`) should cover: completing a PKCE auth on the dev machine and confirming credentials.json appears within seconds, the success page renders, and the Connect device appears in the Spotify app without waiting ~60s for the watchdog — combining this plan's eager path with plan 02's daemon-lifecycle wiring.
- No blockers for closing out Phase 51.

---
*Phase: 51-credential-derivation-connect*
*Completed: 2026-07-14*

## Self-Check: PASSED

- FOUND: Plugins/SpotOn/Settings.pm
- FOUND: Plugins/SpotOn/strings.txt
- FOUND: t/02_strings.t
- FOUND: t/09_settings.t
- FOUND: .planning/phases/51-credential-derivation-connect/51-03-SUMMARY.md
- FOUND commit: f010499 (feat)
- FOUND commit: 683a172 (test)

---
phase: 51-credential-derivation-connect
plan: 01
subsystem: auth
tags: [perl, oauth, pkce, credential-derivation, lms-plugin, librespot, proc-background]

# Dependency graph
requires:
  - phase: 50-perl-tokenmanager-rewrite
    provides: "TokenManager->getToken (cache-or-refresh access token), needsReauth 4-channel infrastructure"
  - phase: 49-pkce-oauth-flow
    provides: "PKCE.pm account-scoped token storage (_accountDir convention), pkce_tokens.json"
provides:
  - "Plugins::SpotOn::API::Credentials — shared derivation module with deriveCredentials, credentialsPathFor, verifyCredentials, accountMismatch, isCredentialError"
  - "Non-blocking spoton --token-login subprocess pattern (Proc::Background + Slim::Utils::Timers poll)"
  - "D-05 rate-limiting primitive (3 failures/5min -> 30min cooldown) ready for daemon crash-loop wiring"
  - "D-08 account-mismatch detection primitive ready for Settings/DaemonManager wiring"
  - "D-03 stderr credential-error classification (isCredentialError) ready for DaemonManager crash-handler wiring"
affects: [51-02-settings-eager-wiring, 51-03-daemonmanager-lazy-wiring]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Async one-shot subprocess: Proc::Background spawn + Slim::Utils::Timers poll, mirrors Daemon::_pollPortFile (never blocking backticks/system())"
    - "In-flight coalescing keyed by accountId with WR-06 eval-guarded callback drain, mirrors TokenManager::_refreshInflight"
    - "File-based success verification only (never subprocess stdout) — same discipline as the SPOTON_TOKEN_FILE Windows fix (commit 9874835)"

key-files:
  created:
    - Plugins/SpotOn/API/Credentials.pm
    - t/16_credentials.t
  modified:
    - t/05_perl_syntax.t

key-decisions:
  - "D-05 rate-limit counter only counts real derivation attempts (spawn_failed/derivation_failed), not pre-flight gate skips (no_token/no_binary/binary_too_old) -- these never reach the Spotify AP so counting them would not serve D-05's anti-hammering purpose (T-51-06)"
  - "accountMismatch reads credentials.json via a raw parse (_readCredsRaw) independent of verifyCredentials's auth_type==1 validation, so a mismatch is still detected even on a not-yet-derivation-verified file, as long as a username is present"
  - "chmod 0600 applied Perl-side after every successful derivation as defense-in-depth (T-51-03), since the Rust binary controls the file's own creation mode and that mode is not directly controlled by this module"

patterns-established:
  - "Credentials.pm module skeleton (constants, package-level in-flight/failure-tracking hashes, _mask convention) is the template plans 02/03 extend for the Settings-eager and DaemonManager-lazy call sites"

requirements-completed: [AUTH-03]

coverage:
  - id: D1
    description: "deriveCredentials converts a fresh PKCE access token into credentials.json (auth_type 1) via non-blocking spoton --token-login, verified by parsing the file (never subprocess stdout)"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/16_credentials.t#Test 1 (happy path), Test 2 (auth_type=3 rejected), Test 3 (missing/corrupt file rejected)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Concurrent derivation requests for the same account coalesce into a single subprocess; a dying callback does not starve other waiters"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/16_credentials.t#Test 6 (coalescing + WR-06 eval-guard)"
        status: pass
    human_judgment: false
  - id: D3
    description: "D-05 rate limiting: 3 failures within 5 minutes triggers a 30-minute cooldown; a subsequent success resets the failure counter"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/16_credentials.t#Test 7 (rate limit + reset)"
        status: pass
    human_judgment: false
  - id: D4
    description: "D-08 account-mismatch detection between credentials.json username and the PKCE account's spotifyUserId"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/16_credentials.t#Test 8 (mismatch/match/absent/corrupt)"
        status: pass
    human_judgment: false
  - id: D5
    description: "D-03 stderr credential-error classification against the exact librespot-core error strings, and no_token/binary_too_old graceful-degradation gates"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/16_credentials.t#Test 4, Test 5, Test 9"
        status: pass
    human_judgment: false
  - id: D6
    description: "T-29-07/T-51-05: the access token is never written to a log line, and credentialsPathFor/spawn args are account-scoped and match the exact --token-login invocation contract"
    requirement: "AUTH-03"
    verification:
      - kind: unit
        ref: "t/16_credentials.t#Test 10 (path scoping), Test 11 (invocation contract), Test 12 (token-free logging)"
        status: pass
    human_judgment: false

# Metrics
duration: 8min
completed: 2026-07-14
status: complete
---

# Phase 51 Plan 01: Credentials.pm Derivation Module Summary

**Shared `Plugins::SpotOn::API::Credentials` module converts a PKCE access token into non-expiring librespot `credentials.json` via non-blocking `spoton --token-login`, with in-flight coalescing, D-05 rate limiting, and D-08 account-mismatch detection — fully unit-tested against a stubbed subprocess.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-07-14T14:27:15Z
- **Completed:** 2026-07-14T14:35:01Z
- **Tasks:** 2
- **Files modified:** 3 (2 created, 1 modified)

## Accomplishments
- `Plugins::SpotOn::API::Credentials` implements the full AUTH-03 derivation contract: `deriveCredentials`, `credentialsPathFor`, `verifyCredentials`, `accountMismatch`, `isCredentialError` — all five public methods from the plan's artifact list.
- Non-blocking subprocess pattern (Proc::Background + Slim::Utils::Timers poll) mirrors `Daemon::_pollPortFile` exactly — no LMS event-loop freeze during the sub-second `--token-login` call.
- 49 new unit tests in `t/16_credentials.t`, covering all 12 required behaviors (happy path, auth_type validation, missing/corrupt file, no_token, binary_too_old, coalescing with WR-06 eval-guard, D-05 rate limit + reset, D-08 mismatch in 4 variants, D-03 error-string classification, path scoping, invocation contract, token-free logging).
- Full test suite green: 554 tests across 16 files (`prove t/`), no regressions.

## Task Commits

Each task was committed atomically:

1. **Task 1: Write t/16_credentials.t (RED)** - `503c614` (test)
2. **Task 2: Implement Credentials.pm + syntax-check registration (GREEN)** - `dc34543` (feat)

**Plan metadata:** (this commit)

## Files Created/Modified
- `Plugins/SpotOn/API/Credentials.pm` - New shared derivation module: deriveCredentials (coalescing → rate-limit gate → binary gates → fresh token via TokenManager → Proc::Background spawn → timer-poll → file-based verification → chmod 0600), credentialsPathFor, verifyCredentials, accountMismatch (D-08), isCredentialError (D-03), plus private _pollDerivation/_accountDir/_mask/_recordFailure/_inCooldown/_resolveInflight/_readCredsRaw/_clearFailures helpers
- `t/16_credentials.t` - Full behavioral test suite (49 assertions) with self-contained LMS stubs (Log, Prefs, Timers, Time::HiRes, JSON::XS::VersionOneAndTwo, Proc::Background, Plugins::SpotOn::Helper, Plugins::SpotOn::API::TokenManager)
- `t/05_perl_syntax.t` - Added `Plugins/SpotOn/API/Credentials.pm` to the `@pm_files` syntax-check list (same convention as PKCE.pm's Phase 49 registration)

## Decisions Made
- D-05's failure counter only counts real derivation-attempt failures (`spawn_failed`/`derivation_failed`), not pre-flight gate skips (`no_token`/`no_binary`/`binary_too_old`) — these never reach the Spotify AP, so counting them would not serve the anti-hammering purpose of T-51-06.
- `accountMismatch` uses a raw JSON read (`_readCredsRaw`) independent of `verifyCredentials`'s `auth_type==1` validation — a mismatch must be detectable even against a credentials.json that exists but hasn't (yet) passed full derivation-success validation, as long as it has a `username` field.
- `chmod 0600` is applied Perl-side after every successful derivation as defense-in-depth (T-51-03), since the module doesn't directly control the Rust binary's file-creation mode.
- Internal `_pollDerivation` state uses a single hashref (`{proc, accountId, resolve, attempts}`) passed as the timer "object" argument, matching the `Daemon::_pollPortFile` convention of receiving `$self`-equivalent state as the first callback argument.

## Deviations from Plan

None - plan executed exactly as written. All 12 required test behaviors, all 5 public methods, and all grep-verified acceptance criteria (no `qx`/`system`, no direct `loadTokens` calls, no stdout-based `credentials_saved` detection, no `remove_tree`) were satisfied without needing any Rule 1-4 deviations.

## Issues Encountered
None.

## Known Stubs

None. This plan is a pure backend module + its unit tests — no UI-facing code, no hardcoded empty/placeholder values. The module is not yet wired into any call site (Settings.pm eager path, DaemonManager.pm lazy path) — that wiring is explicitly plans 02 and 03's scope per the phase's own artifact/wave structure, not a stub or gap in this plan's delivered scope.

## User Setup Required

None - no external service configuration required. This phase's `--token-login` subcommand is already present in the currently-bundled `spoton` binary (verified via `Helper->getCapability('token-login')` gate added in this plan).

## Next Phase Readiness

- `Credentials.pm`'s five public methods are ready for Plan 02 (Settings-eager wiring, D-01/D-02/D-06) and Plan 03 (DaemonManager-lazy wiring, D-03/D-04/D-07) to consume directly.
- `isCredentialError` is ready for DaemonManager's crash-handler to call once stderr capture is made unconditional of `diagnosticMode` (RESEARCH.md Pitfall 1 — that stderr-always-capture change is separately scoped to plan 03, not addressed in this plan).
- `accountMismatch` only detects; the delete-single-file-then-re-derive flow (D-08) and the ZeroConf-guest-protection verification (D-09, already implemented Rust-side) remain to be wired/documented in plans 02/03.
- No blockers.

---
*Phase: 51-credential-derivation-connect*
*Completed: 2026-07-14*

## Self-Check: PASSED

- FOUND: Plugins/SpotOn/API/Credentials.pm
- FOUND: t/16_credentials.t
- FOUND: .planning/phases/51-credential-derivation-connect/51-01-SUMMARY.md
- FOUND commit: 503c614 (test)
- FOUND commit: dc34543 (feat)

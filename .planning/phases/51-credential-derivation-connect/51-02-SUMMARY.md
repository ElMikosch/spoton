---
phase: 51-credential-derivation-connect
plan: 02
subsystem: auth
tags: [perl, librespot, daemon-lifecycle, spotify-connect, lms-plugin, credential-derivation]

# Dependency graph
requires:
  - phase: 51-credential-derivation-connect (plan 01)
    provides: "Plugins::SpotOn::API::Credentials — deriveCredentials, credentialsPathFor, verifyCredentials, accountMismatch, isCredentialError"
  - phase: 50-perl-tokenmanager-rewrite
    provides: "TokenManager->getToken (cache-or-refresh), _markNeedsReauth 4-channel escalation infrastructure"
provides:
  - "Daemon.pm always-on bounded stderr capture (independent of diagnosticMode) + stderrTail($maxBytes) accessor"
  - "DaemonManager::startHelper lazy derivation safety-net (D-01) — self-heals missing credentials.json from PKCE tokens"
  - "DaemonManager::startHelper D-08 account-mismatch repair — deletes and re-derives on cross-account credential mismatch"
  - "DaemonManager::_handleCredentialCrash (D-03) — credential-rejection crash classification, delete->re-derive->restart"
  - "TokenManager::markNeedsReauth — PUBLIC wrapper around the private D-08 escalation implementation, cross-module D-04 API"
  - "D-09 Rust-side guest ZeroConf credential isolation verified present (unified.rs L1261) and documented, not rebuilt in Perl"
affects: [51-03-settings-eager-wiring]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Credential-crash classification: read Daemon::stderrTail(8192) before the generic crash-restart branch, route to _handleCredentialCrash only when Credentials->isCredentialError matches"
    - "Masked-accountId logging convention (_maskAccountId) extended into DaemonManager.pm, mirroring TokenManager::_mask/Credentials::_mask"
    - "Public-wrapper-around-private-escalation convention (markNeedsReauth/clearNeedsReauth) for cross-module 4-channel re-auth API"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Unified/Daemon.pm
    - Plugins/SpotOn/Unified/DaemonManager.pm
    - Plugins/SpotOn/API/TokenManager.pm

key-decisions:
  - "diagnosticMode OFF now truncates the same per-daemon stderr file on every start (instead of routing to devnull) rather than using a separate ring-buffer/tempfile mechanism -- simplest change that satisfies Pitfall 1's requirement (stderr always readable) while keeping the existing filename/glob-cleanup contract untouched"
  - "D-08 mismatch repair and D-01 lazy safety-net are both gated on a non-empty activeAccountId (Pitfall 4) -- legacy flat-dir credential setups are left completely untouched by this plan, exactly as scoped to D-10/Phase 53"
  - "_handleCredentialCrash treats 'no_token' as already-flagged (TokenManager's own internal getToken/needsReauth logic already escalated), and only escalates itself for 'derivation_failed' -- avoids a double 4-channel warning for the same underlying token failure"

patterns-established:
  - "Lazy-require + retry-on-success shape for daemon-lifecycle self-healing: startHelper's D-01 branch and _streamAlivePoll's D-03 branch both call Credentials->deriveCredentials and re-invoke the calling entry point (startHelper) on success rather than duplicating start logic"

requirements-completed: [AUTH-03, AUTH-04]

coverage:
  - id: D1
    description: "Daemon.pm captures stderr to a bounded per-daemon file in ALL configurations (diagnosticMode on or off) and exposes it via stderrTail($maxBytes) for crash classification"
    requirement: "AUTH-04"
    verification:
      - kind: unit
        ref: "prove t/ (full suite regression, 554 tests) -- no dedicated behavioral test added, existing suite exercises Daemon.pm indirectly via DaemonManager stubs where present"
        status: pass
      - kind: other
        ref: "grep gates: 'sub stderrTail' count=1, 'devnull' count=0, 'unified.log' count=1, untie/retie block intact"
        status: pass
    human_judgment: true
    rationale: "No dedicated Daemon.pm/DaemonManager.pm test harness exists in t/ (unlike TokenManager.pm/Credentials.pm, which have t/07_token_manager.t/t/16_credentials.t) -- structural grep gates and full-suite regression confirm the code compiles and doesn't break existing behavior, but the actual self-healing behavior (crash -> stderr classification -> delete -> re-derive -> restart) requires a live daemon lifecycle to exercise, which is exactly the manual UAT this phase's own verification section reserves for AUTH-04 end-to-end (spoton-uat / pi-playback-test skills)."
  - id: D2
    description: "startHelper self-heals a missing credentials.json by deriving from PKCE tokens when the active account has them (D-01), and repairs a cross-account credential mismatch by deleting and re-deriving without user confirmation (D-08) -- both scoped exclusively to the account-scoped path (Pitfall 4)"
    requirement: "AUTH-04"
    verification:
      - kind: unit
        ref: "prove t/ (full suite regression, 554 tests)"
        status: pass
      - kind: other
        ref: "grep gates: 'deriveCredentials' count=2, 'accountMismatch' count=1, 'remove_tree' count=0, account-change (D-07) block unmodified, no direct PKCE token handling in DaemonManager"
        status: pass
    human_judgment: true
    rationale: "Same rationale as D1 -- structural verification only; live self-heal behavior requires a real PKCE account + daemon start cycle, reserved for manual UAT."
  - id: D3
    description: "_streamAlivePoll classifies a crashed daemon's stderr before restarting; credential-rejection crashes route to _handleCredentialCrash (delete -> re-derive -> restart, D-03) with D-05 cooldown; permanent AP rejection escalates via TokenManager->markNeedsReauth (D-04), daemon stays stopped; generic crashes restart exactly as before"
    requirement: "AUTH-04"
    verification:
      - kind: unit
        ref: "prove t/ (full suite regression, 554 tests)"
        status: pass
      - kind: other
        ref: "grep gates: 'sub _handleCredentialCrash' count=1, 'isCredentialError' count=2, 'stderrTail' count=1, 'sub markNeedsReauth' count=1, 'sub _markNeedsReauth' count=1 (intact), 'TokenManager->markNeedsReauth' count=1, no private-method reach-in from DaemonManager"
        status: pass
    human_judgment: true
    rationale: "Crash-loop self-healing and the 4-channel escalation firing correctly require a real credential-rejection scenario against a live Spotify account -- not mockable in the existing t/ harness (no Proc::Background-crash-simulation stub exists for Daemon.pm). Reserved for manual UAT per this phase's own verification section."
  - id: D4
    description: "D-09 guest ZeroConf credential isolation verified present in the Rust binary (unified.rs 'Phase 14 (Credential Isolation)', line 1261) and documented in a comment above _handleCredentialCrash -- not rebuilt in Perl"
    requirement: "AUTH-04"
    verification:
      - kind: other
        ref: "grep -n 'Phase 14 (Credential Isolation)' librespot-spoton/src/unified.rs -> line 1261 match; grep 'reconnect_cache' count=0 in DaemonManager.pm (no Perl reimplementation)"
        status: pass
    human_judgment: false

# Metrics
duration: 9min
completed: 2026-07-14
status: complete
---

# Phase 51 Plan 02: Daemon Lifecycle Credential Wiring Summary

**Wired Plan 01's shared `Credentials.pm` derivation module into the daemon lifecycle: always-on stderr capture (fixing the diagnosticMode-gated stderr gap that silently broke crash detection), a lazy self-heal safety-net for missing credentials, D-08 cross-account mismatch repair, and D-03/D-04 crash-triggered auto-re-derive with 4-channel escalation on permanent failure.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-07-14T14:36:00Z
- **Completed:** 2026-07-14T14:44:33Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- `Daemon.pm` now captures stderr to the same bounded per-daemon file in every configuration — the `diagnosticMode`-gated `/dev/null` branch (Pitfall 1) that silently made D-03's credential-error detection impossible in the default configuration is gone. `stderrTail($maxBytes)` exposes the last 8KB for crash classification.
- `DaemonManager::startHelper` self-heals two situations without user intervention: a missing `credentials.json` when PKCE tokens exist for the active account (D-01 lazy safety-net, retries `startHelper` on successful derivation), and a `credentials.json` belonging to a different Spotify user than the active PKCE account (D-08, delete-single-file-then-fall-through, no confirmation).
- `_streamAlivePoll`'s crash branch now classifies the dying daemon's stderr tail before restarting: a credential-rejection error routes to the new `_handleCredentialCrash` (delete → re-derive → restart, D-03, rate-limited by D-05's cooldown inside `Credentials.pm`); every other crash restarts exactly as before, byte-for-byte unchanged.
- Permanent re-derivation failure (`derivation_failed` — the PKCE token was fresh but the AP rejected the exchange) escalates through a new `TokenManager::markNeedsReauth` **public** wrapper, mirroring the existing `clearNeedsReauth` convention, so `DaemonManager` never reaches into `TokenManager`'s private `_markNeedsReauth` implementation.
- D-09 (guest ZeroConf overwrite protection) confirmed still present in the Rust fork (`librespot-spoton/src/unified.rs` line 1261, `"Phase 14 (Credential Isolation)"`) and documented in a comment above `_handleCredentialCrash` — verified, not rebuilt in Perl.
- D-10 (legacy flat-dir cleanup) recorded as deferred to Phase 53: both new branches in `startHelper` are gated on a non-empty `activeAccountId`; when it's empty, the pre-existing flat-dir behavior is completely untouched.
- Full suite green throughout: 554 tests across 16 files, no regressions.

## Task Commits

Each task was committed atomically:

1. **Task 1: Daemon.pm — always-on bounded stderr capture + stderrTail accessor** - `60a2c03` (feat)
2. **Task 2: DaemonManager.pm — lazy derivation safety-net + D-08 mismatch repair in startHelper** - `4185eb1` (feat)
3. **Task 3: DaemonManager.pm + TokenManager.pm — D-03 crash handling, public D-04 escalation API + D-09 verification** - `12ff7d3` (feat)

**Plan metadata:** (this commit)

## Files Created/Modified
- `Plugins/SpotOn/Unified/Daemon.pm` — stderr capture is now unconditional (append when diagnosticMode, truncate-on-start otherwise), removed the devnull branch and the now-unused `File::Spec` import; added `stderrTail($self, $maxBytes)`.
- `Plugins/SpotOn/Unified/DaemonManager.pm` — `startHelper` extended with D-08 mismatch repair and D-01 lazy derivation (both account-scoped only, Pitfall 4); `_streamAlivePoll` classifies crashes via `stderrTail` + `Credentials->isCredentialError`; new `_handleCredentialCrash` (D-03/D-04/D-09-documentation) and `_maskAccountId` helper; new `STDERR_TAIL_BYTES` constant.
- `Plugins/SpotOn/API/TokenManager.pm` — new public `markNeedsReauth($class, $accountId, $reason)` thin wrapper delegating to the existing private `_markNeedsReauth`, placed next to `clearNeedsReauth` in the "Public class methods" section.

## Decisions Made
- diagnosticMode OFF now truncates the same per-daemon stderr file on every start (rather than a separate ring buffer or bounded tempfile) — the simplest change satisfying Pitfall 1 while preserving the existing filename and `_cleanupOrphanedLogs` glob contract unchanged.
- D-08 mismatch repair and D-01 lazy safety-net are both gated on a non-empty `activeAccountId` (Pitfall 4) — legacy flat-dir credential setups are left completely untouched, matching the D-10 deferral to Phase 53.
- `_handleCredentialCrash` only self-escalates for `derivation_failed`; it treats `no_token` as already-flagged (TokenManager's own `getToken`/`needsReauth` logic escalates internally) to avoid firing a duplicate 4-channel warning for the same underlying token failure.

## Deviations from Plan

None — plan executed exactly as written. All acceptance-criteria grep gates (stderrTail count, devnull removal, deriveCredentials/accountMismatch wiring, remove_tree absence, D-07 block preservation, `_handleCredentialCrash`/`isCredentialError`/`stderrTail` presence, public/private `markNeedsReauth` split, D-09 Rust marker, no `reconnect_cache` reimplementation) were satisfied without needing any Rule 1-4 deviations. `File::Spec` import removal in Daemon.pm was a direct, in-scope consequence of removing the devnull branch (not a separate deviation).

## Issues Encountered
None.

## Known Stubs

None. All three tasks deliver fully wired, functioning code — no placeholder values, no hardcoded empty states, no UI-facing stubs. The lazy derivation and crash-handling call sites are real, reachable code paths (not scaffolding for a future plan).

## User Setup Required

None — no external service configuration required. This plan reuses the already-bundled `spoton` binary's `--token-login` capability (verified in Plan 01) and existing LMS-bundled modules only.

## Next Phase Readiness

- The daemon lifecycle now reaches `Credentials.pm`'s derivation entry point from both self-heal paths required by AUTH-04: missing credentials (lazy, D-01) and rejected credentials (crash-triggered, D-03).
- `TokenManager::markNeedsReauth` is available as the cross-module D-04 escalation API for any future call site that needs to flag an account for re-auth without reaching into TokenManager's private method.
- Manual UAT for AUTH-04's true end-to-end behavior (Connect device visible in the Spotify app, self-heal actually firing against a live account) is still required per this phase's own verification section — no dedicated Daemon.pm/DaemonManager.pm test harness exists in `t/`, so this plan's automated coverage is structural (grep gates + full-suite regression), not behavioral. This is consistent with the phase's own Validation Architecture, which already reserves AUTH-04 end-to-end as manual-only.
- No blockers. Plan 03 (Settings-eager wiring, D-02/D-06) can proceed independently — it consumes the same `Credentials.pm` module without depending on any of this plan's DaemonManager/TokenManager changes.

---
*Phase: 51-credential-derivation-connect*
*Completed: 2026-07-14*

## Self-Check: PASSED

- FOUND: Plugins/SpotOn/Unified/Daemon.pm
- FOUND: Plugins/SpotOn/Unified/DaemonManager.pm
- FOUND: Plugins/SpotOn/API/TokenManager.pm
- FOUND: .planning/phases/51-credential-derivation-connect/51-02-SUMMARY.md
- FOUND commit: 60a2c03 (feat)
- FOUND commit: 4185eb1 (feat)
- FOUND commit: 12ff7d3 (feat)

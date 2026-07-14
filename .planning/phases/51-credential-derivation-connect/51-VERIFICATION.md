---
phase: 51-credential-derivation-connect
verified: 2026-07-14T18:30:00Z
status: human_needed
score: 11/15 must-haves verified
behavior_unverified: 4
overrides_applied: 0
behavior_unverified_items:
  - truth: "When credentials.json is missing but PKCE tokens exist, daemon start self-heals by deriving credentials and then starting the daemon (D-01 lazy safety-net)"
    test: "Configure a PKCE account, manually delete the account's credentials.json, then trigger startHelper (player connect or LMS restart) and observe the daemon log."
    expected: "Log shows 'deriving from PKCE tokens (D-01 lazy safety-net)' then 'Lazy credential derivation succeeded ... retrying daemon start'; credentials.json reappears; daemon starts and the Connect device shows up in the Spotify app."
    why_human: "No Daemon.pm/DaemonManager.pm test harness exists in t/ (unlike TokenManager.pm/Credentials.pm) — the wiring is grep-verified and code-read-verified, but the actual state transition (delete -> self-heal -> daemon start) requires a live spoton binary + real/stubbed PKCE tokens, which is exactly the manual UAT this phase's own 51-VALIDATION.md and PLAN verification sections reserve for AUTH-04."
  - truth: "A daemon crash caused by rejected credentials auto-deletes credentials.json, re-derives from PKCE tokens, and restarts — transparent to the user (D-03)"
    test: "Force a daemon crash whose stderr tail contains one of the three librespot-core credential-rejection strings (e.g. corrupt the stored auth_data so the AP rejects it), then observe _streamAlivePoll's next cycle."
    expected: "_handleCredentialCrash fires (WARN log), credentials.json is unlinked, deriveCredentials re-derives, and startHelper restarts the daemon without any user action."
    why_human: "Same as above — no automated crash-simulation stub exists for Daemon.pm's Proc::Background lifecycle; requires a live/near-live daemon crash to exercise the branch."
  - truth: "When re-derivation fails permanently, the 4-channel re-auth warning fires and the daemon stays stopped (D-04)"
    test: "Force _handleCredentialCrash's re-derive callback to receive reason='derivation_failed' (fresh token rejected by AP) and observe TokenManager's 4-channel escalation (cache flag, Status page, etc.) plus confirm startHelper does not restart the daemon."
    expected: "TokenManager->markNeedsReauth(accountId, 'derivation_failed') fires exactly once; the daemon remains stopped because startHelper's credential pre-check finds no credentials.json."
    why_human: "Requires driving _handleCredentialCrash's failure branch end-to-end against a real/near-real derivation failure; not covered by any existing unit test."
  - truth: "credentials.json belonging to a different Spotify user than the active PKCE account is deleted and re-derived without user confirmation (D-08)"
    test: "Write a credentials.json with a foreign username into the active account's cache dir, then call startHelper."
    expected: "Log shows 'belong to a different Spotify user — deleting and re-deriving' (D-08), the single credentials.json file is unlinked (pkce_tokens.json untouched), and the lazy D-01 branch immediately re-derives fresh credentials for the active account."
    why_human: "Credentials->accountMismatch() itself IS unit-tested (t/16_credentials.t Test 8), but the full startHelper wiring (detect -> unlink -> fall through -> re-derive) has no DaemonManager-level test exercising it end-to-end."
overrides: []
gaps: []
---

# Phase 51: Credential Derivation + Connect Verification Report

**Phase Goal:** Convert PKCE access tokens to stored credentials for librespot Connect sessions. Ensure Connect registration and audio playback work with PKCE-derived credentials. (AUTH-03, AUTH-04)
**Verified:** 2026-07-14T18:30:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

No `success_criteria` were defined in ROADMAP.md for Phase 51 (empty array via `roadmap.get-phase`), so must-haves were sourced entirely from the three PLAN.md frontmatter blocks (51-01, 51-02, 51-03), merged without reduction.

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Credentials.pm converts a fresh PKCE access token into credentials.json (auth_type 1) via `spoton --token-login` without blocking the LMS event loop | ✓ VERIFIED | `Plugins/SpotOn/API/Credentials.pm` `deriveCredentials` spawns via `Proc::Background` + `Slim::Utils::Timers` poll (no `qx`/`system`, grep gate =0); `t/16_credentials.t` Test 1 (happy path) passes |
| 2 | Derivation success is verified by parsing credentials.json, never subprocess stdout | ✓ VERIFIED | `verifyCredentials` reads/parses the file only; `grep -c credentials_saved` = 0; Tests 1-3 pass (auth_type=3 rejected, missing/corrupt file rejected) |
| 3 | Concurrent derivation requests for the same account coalesce into a single subprocess | ✓ VERIFIED | `%_deriveInflight` queue + WR-06 eval-guarded drain (`_resolveInflight`); `t/16_credentials.t` Test 6 passes |
| 4 | Repeated derivation failures are rate-limited: 3 failures/5min → 30min cooldown (D-05) | ✓ VERIFIED | `_recordFailure`/`_inCooldown` constants match spec exactly (3/300s/1800s); Test 7 passes |
| 5 | Account mismatch between credentials.json username and the PKCE account's spotifyUserId is detectable (D-08) | ✓ VERIFIED | `accountMismatch` implemented per spec; Test 8 (4 variants) passes |
| 6 | When credentials.json is missing but PKCE tokens exist, daemon start self-heals by deriving credentials then starting the daemon (D-01 lazy safety-net) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `startHelper` in `DaemonManager.pm` (lines ~529-567) implements the exact branch read in the plan; no automated test exercises the live self-heal transition — see Human Verification |
| 7 | A daemon crash caused by rejected credentials auto-deletes credentials.json, re-derives, and restarts (D-03) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `_streamAlivePoll` → `_handleCredentialCrash` wired and code-correct (lines 336-460); no live-crash test exists — see Human Verification |
| 8 | Credential-error detection works in the DEFAULT configuration (diagnosticMode off) — stderr always captured (Pitfall 1) | ✓ VERIFIED | `Daemon.pm` opens the `-unified.log` file unconditionally (`$openMode = $diagMode ? '>>' : '>'`); `devnull` branch removed entirely (grep=0); confirmed by direct code read, not just structural inference |
| 9 | When re-derivation fails permanently, the 4-channel re-auth warning fires and the daemon stays stopped (D-04) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `_handleCredentialCrash`'s `derivation_failed` branch calls `TokenManager->markNeedsReauth` (public wrapper, confirmed delegates to `_markNeedsReauth`); no live-failure test — see Human Verification |
| 10 | credentials.json belonging to a different Spotify user is deleted and re-derived without user confirmation (D-08) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `startHelper`'s mismatch-repair branch (lines 513-527) calls `accountMismatch` + `unlink` + falls through to lazy re-derive; underlying `accountMismatch` is unit-tested but the full DaemonManager wiring is not — see Human Verification |
| 11 | A LAN guest via ZeroConf can never overwrite the on-disk credentials.json (D-09 — verified Rust-side, not rebuilt in Perl) | ✓ VERIFIED | `librespot-spoton/src/unified.rs` line 1261 confirmed present: `"Phase 14 (Credential Isolation)"` reconnect_cache without `credentials_location`; `DaemonManager.pm` documents but does not re-implement (`reconnect_cache` grep=0) — this matches the plan's own "verify, do not rebuild" scope |
| 12 | Completing PKCE auth in Settings immediately derives credentials.json while the token is guaranteed fresh (D-01 eager call site) | ✓ VERIFIED | `Settings.pm` `_pkceStoreAccount` calls `Credentials->deriveCredentials` inside the `_storeAccountPrefs` success callback (single call site, grep=1); `t/09_settings.t` functional test exercises the real code path against stubbed `Credentials` |
| 13 | On derivation success the success page renders and daemon start triggers unconditionally (D-06, Pitfall 6) | ✓ VERIFIED | `scheduleInit()` call sits inside the `$ok` branch, unconditional on any first-account check; `t/09_settings.t` "Pitfall 6" test asserts `scheduleInit` fires even when `activeAccount` was already set before the flow |
| 14 | On derivation failure the user sees a warning but account creation still succeeds (D-02) | ✓ VERIFIED | Failure branch renders `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED`/`connectReady:0` without any rollback of stored tokens; `t/09_settings.t` D-02 test confirms account creation is not rolled back |
| 15 | The success message fires only after derivation completes (OAuth success no longer conflated with Connect-readiness) | ✓ VERIFIED | `_renderPkceResultPage(... PLUGIN_SPOTON_PKCE_SUCCESS ...)` is nested inside `deriveCredentials`'s `$ok` callback, not the outer `_storeAccountPrefs` callback |

**Score:** 11/15 truths verified (4 present, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Plugins/SpotOn/API/Credentials.pm` | Shared derivation module, 5 public methods | ✓ VERIFIED | All 5 methods present (`deriveCredentials`, `credentialsPathFor`, `verifyCredentials`, `accountMismatch`, `isCredentialError`); wired into both DaemonManager.pm and Settings.pm |
| `t/16_credentials.t` | Unit coverage for all 12 behaviors | ✓ VERIFIED | 49 assertions, `prove t/16_credentials.t` passes |
| `Plugins/SpotOn/Unified/Daemon.pm` | Always-on stderr capture + `stderrTail()` | ✓ VERIFIED | `sub stderrTail` present (1), `devnull` branch removed (0), filename contract preserved |
| `Plugins/SpotOn/Unified/DaemonManager.pm` | Lazy derivation, D-08 repair, D-03 crash handling | ✓ VERIFIED | `deriveCredentials` (3 call sites), `accountMismatch` (1), `_handleCredentialCrash` (1), `isCredentialError` (2), `stderrTail` (1) |
| `Plugins/SpotOn/API/TokenManager.pm` | Public `markNeedsReauth` wrapper | ✓ VERIFIED | `sub markNeedsReauth` (1, public) delegates to `sub _markNeedsReauth` (1, private, unmodified) |
| `Plugins/SpotOn/Settings.pm` | Eager derivation call site | ✓ VERIFIED | Single `deriveCredentials` call site inside `_pkceStoreAccount`; `scheduleInit` count increased by exactly 1 (2 total) |
| `Plugins/SpotOn/strings.txt` | `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED`, 11 languages | ✓ VERIFIED | Block present, all 11 language codes (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV) confirmed |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `Credentials.pm` | `TokenManager.pm` | `TokenManager->getToken` for fresh access token | ✓ WIRED | Line 108, never reads `PKCE::loadTokens` directly (grep=0) |
| `Credentials.pm` | `spoton` binary | `Proc::Background` spawn of `--token-login` | ✓ WIRED | Lines 126-133, invocation contract matches (`--token-login`, `--token`, `--cache`) |
| `DaemonManager.pm` | `Credentials.pm` | `deriveCredentials` in `startHelper` + `_handleCredentialCrash` | ✓ WIRED | 3 call sites confirmed |
| `DaemonManager.pm` | `Daemon.pm` | `stderrTail` read in crash branch | ✓ WIRED | `_streamAlivePoll` reads `$helper->stderrTail(STDERR_TAIL_BYTES)` before classification |
| `DaemonManager.pm` | `TokenManager.pm` | `TokenManager->markNeedsReauth` on permanent failure | ✓ WIRED | Exactly 1 call site, never reaches into `_markNeedsReauth` directly (grep=0) |
| `Settings.pm` | `Credentials.pm` | `deriveCredentials` inside `_pkceStoreAccount` | ✓ WIRED | Single call site inside `_storeAccountPrefs` success callback |
| `Settings.pm` | `DaemonManager.pm` | unconditional `scheduleInit` on derivation success | ✓ WIRED | Fires inside the `$ok` branch only, independent of first-account state |

### Data-Flow Trace (Level 4)

Not applicable — this phase modifies backend/daemon-lifecycle Perl modules and a Settings HTTP handler, not UI components that render dynamic collections. The relevant "data flow" (PKCE token → credentials.json → daemon start) is covered under Key Link Verification above.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full regression suite green | `prove t/` | `Files=16, Tests=564, Result: PASS` (run once, independently, in this verification session — not taken from SUMMARY.md) | ✓ PASS |
| Credentials.pm unit behaviors | (included in `prove t/` above; `t/16_credentials.t` is one of the 16 files) | `t/16_credentials.t ...... ok` | ✓ PASS |
| Settings.pm functional eager-derivation tests | (included in `prove t/` above; `t/09_settings.t` is one of the 16 files) | `t/09_settings.t ......... ok` | ✓ PASS |
| Live daemon self-heal / crash-triggered re-derive / D-04 escalation | N/A — no runnable entry point in this harness (requires live spoton binary + real/near-real Spotify AP interaction) | — | ? SKIP — routed to human verification |

### Probe Execution

No `scripts/*/tests/probe-*.sh` files found in this repository and none declared in the phase's PLAN/SUMMARY files. Skipped.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| AUTH-03 | 51-01, 51-02, 51-03 | PKCE access token used once to obtain non-expiring librespot stored credentials | ✓ SATISFIED | `Credentials.pm` derivation module (unit-tested) + eager Settings call site (unit-tested) + lazy DaemonManager call site (code-verified, behavior deferred to manual UAT) |
| AUTH-04 | 51-02 | librespot starts with stored credentials, Connect device registers via cloud/Spirc | ? NEEDS HUMAN | Daemon-lifecycle wiring (self-heal, crash auto-re-derive, D-04 escalation) is code-correct and grep-verified but requires a live Spotify Connect handshake to confirm end-to-end — this phase's own `51-VALIDATION.md` explicitly reserves this as "Manual-Only" |

No orphaned requirements found: `grep -n "Phase 51"` in REQUIREMENTS.md returns nothing (REQUIREMENTS.md does not map requirement IDs to phase numbers directly), but cross-referencing the Auth Architecture section confirms AUTH-03 and AUTH-04 are both checked off `[x]` and both are declared in the PLAN frontmatter `requirements:` fields of this phase's three plans — no additional phase-51-tagged requirement IDs exist that were left unclaimed.

### Anti-Patterns Found

None. Scanned all 5 modified/created production files (`Credentials.pm`, `Daemon.pm`, `DaemonManager.pm`, `TokenManager.pm`, `Settings.pm`) for `TBD|FIXME|XXX|TODO|HACK|PLACEHOLDER` and placeholder-language patterns. The only regex hit (`XXXX` in `Daemon.pm` line 195) is a `File::Temp::tempfile()` template placeholder (`'spoton-port-XXXX'`), not a debt marker — pre-existing code, unrelated to this phase's changes.

### Human Verification Required

These items combine (a) the 4 behavior-dependent truths left ⚠️ PRESENT_BEHAVIOR_UNVERIFIED above, and (b) the two phase-level manual UAT items this phase's own PLAN.md `<verification>` sections and `51-VALIDATION.md` explicitly reserve (not a gap — a deliberate, documented scoping decision by the plan authors, consistent with `human_judgment: true` markings in the 51-02 SUMMARY coverage table).

#### 1. Lazy self-heal on missing credentials (D-01)

**Test:** With a PKCE-authenticated account, delete `{cachedir}/spoton/{accountId}/credentials.json` while leaving `pkce_tokens.json` intact, then trigger a daemon start (player connect, or restart LMS).
**Expected:** Log shows the D-01 lazy safety-net firing, `credentials.json` reappears, and the daemon starts successfully.
**Why human:** No DaemonManager.pm test harness exists in `t/`; requires a live spoton binary and PKCE tokens.

#### 2. Crash-triggered auto-re-derive (D-03) and permanent-failure escalation (D-04)

**Test:** Force a daemon crash whose stderr contains a librespot-core credential-rejection string (e.g. corrupt `auth_data` in `credentials.json` before a restart), then observe two outcomes: (a) a successful re-derive restarts transparently, (b) a permanently-rejected fresh token triggers the 4-channel re-auth warning and the daemon stays stopped.
**Expected:** `_handleCredentialCrash` deletes+re-derives+restarts on recoverable failures; `TokenManager->markNeedsReauth` fires exactly once and the daemon does not restart on `derivation_failed`.
**Why human:** Requires driving a live daemon crash + AP rejection; not mockable in the existing `t/` harness (no Proc::Background crash-simulation stub for Daemon.pm).

#### 3. Cross-account credential mismatch repair (D-08, full wiring)

**Test:** Write a `credentials.json` for a different Spotify username into the active account's cache dir, then trigger `startHelper`.
**Expected:** The mismatched file is deleted (not the whole account dir), and a fresh derivation immediately follows for the active PKCE account.
**Why human:** The underlying `accountMismatch()` primitive is unit-tested, but the full `startHelper` detect→delete→re-derive wiring has no DaemonManager-level test.

#### 4. AUTH-04 end-to-end: Connect device visibility + playback

**Test:** With a PKCE-authenticated account and `--disable-discovery` set for a player, confirm the Connect device appears in the Spotify app ("In anderen Netzwerken") and playback works. Use the `spoton-uat` or `pi-playback-test` project skill.
**Expected:** Connect device visible and controllable from the Spotify app; audio plays through the LMS player.
**Why human:** Requires a live Spotify Premium account and a real Connect/Spirc handshake — this is explicitly declared as the phase's only "Manual-Only" verification in `51-VALIDATION.md`.

#### 5. Settings eager flow end-to-end timing

**Test:** Complete a PKCE auth in LMS Settings on the dev machine.
**Expected:** `credentials.json` appears in the account dir within seconds, the success page renders, and the Connect device appears without waiting ~60s for the watchdog.
**Why human:** Requires a live LMS + Settings UI + real Spotify OAuth round-trip (per plan 51-03's own `<verification>` section).

### Gaps Summary

No gaps found — every artifact exists, is substantive, and is wired exactly as the three plans specify; all grep/structural acceptance criteria pass; the full test suite (564 tests, 16 files) is green when run independently in this verification session. The reason overall status is `human_needed` rather than `passed` is that 4 of the 15 must-have truths describe daemon-lifecycle state transitions (self-heal, crash-triggered re-derive, permanent-failure escalation, mismatch repair) that have no automated test harness in this codebase (Daemon.pm/DaemonManager.pm lack a stub-based test file, unlike Credentials.pm/TokenManager.pm/Settings.pm) — this is a pre-existing, documented gap in test infrastructure that the plan authors themselves flagged (`human_judgment: true` in 51-02's SUMMARY coverage table) and explicitly deferred to manual UAT via `51-VALIDATION.md`'s "Manual-Only Verifications" table. The code implementing these truths was read line-by-line and matches the plan's specification exactly — the uncertainty is purely about live runtime behavior, not code correctness.

---

*Verified: 2026-07-14T18:30:00Z*
*Verifier: Claude (gsd-verifier)*

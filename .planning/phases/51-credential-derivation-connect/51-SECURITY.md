---
phase: 51-credential-derivation-connect
audited: 2026-07-14
asvs_level: 1 (no explicit <config> block found in 51-01-PLAN.md; STRIDE register itself demonstrates L2-consistent discipline — mitigate applied to all medium+ threats with no unrationalized accepts — so L2 verification depth was applied regardless of the L1 default)
block_on: high (default; no explicit block_on found in PLAN.md <config>)
threats_total: 5
threats_closed: 5
threats_open: 0
unregistered_flags: 0
---

# Phase 51 Security Verification — Credential Derivation + Connect

## Scope

Verified the STRIDE threat register in `.planning/phases/51-credential-derivation-connect/51-01-PLAN.md` (`<threat_model>` block, T-51-02 through T-51-06) against the actual implementation in `Plugins/SpotOn/API/Credentials.pm`, `Plugins/SpotOn/Unified/Daemon.pm`, `Plugins/SpotOn/Unified/DaemonManager.pm`, `Plugins/SpotOn/Settings.pm`, and `librespot-spoton/src/main.rs`. Every threat was traced to its actual mitigating code path (not accepted on the basis of comments, plan text, or the code review's own description of a fix) and cross-checked against all three `deriveCredentials` call sites (Settings.pm eager, DaemonManager.pm lazy safety-net, DaemonManager.pm crash-triggered), since a shared-module mitigation only counts as closed if it demonstrably covers every entry point.

T-51-05 required special attention: its disposition changed from `accept` (original plan) to `mitigate` after CR-01 was fixed during code review (`51-REVIEW.md`). Both sides of that fix — the Perl caller and the Rust binary — were independently verified below; the review document's own description of the fix was **not** treated as sufficient evidence.

## Threat Verification

| Threat ID | Category | Severity | Disposition | Status | Evidence |
|-----------|----------|----------|-------------|--------|----------|
| T-51-02 | Tampering | medium | mitigate | **CLOSED** | `Plugins/SpotOn/API/Credentials.pm:211-221` (`verifyCredentials`: `auth_type==1` check L216, non-empty `username` L217, non-empty `auth_data` L218, never trusts exit code); consumed as the sole success gate in `_pollDerivation` L290-292 (`if ($creds) { ... } else { _recordFailure; resolve(0,'derivation_failed') }`). Reinforced by the WR-04 fix (`Credentials.pm:130-136`, `unlink $credFile if -f $credFile` before every spawn) which closes the code-review-identified gap where a stale pre-existing file could be misread as a fresh success. |
| T-51-03 | Information Disclosure | high | mitigate | **CLOSED** | `Plugins/SpotOn/API/Credentials.pm:294-296` — `chmod(0600, $credFile) if -f $credFile` immediately after every successful derivation inside `_pollDerivation`. Account dir: `Credentials.pm:121-127` — `File::Path::make_path($accountDir, { mode => 0700 })` on the lazy/crash paths (IN-02 fix); `Plugins/SpotOn/Settings.pm:506` — `chmod(0700, $accountDir) if -d $accountDir` on the eager path (T-04.3-07 pattern). Both the 0600 file perm and the 0700 dir perm are present on every code path that can create the directory or the file. |
| T-51-04 | DoS / Tampering | medium | mitigate | **CLOSED** (primary control verified; secondary claim unverifiable in-repo, non-blocking) | Primary: `Plugins/SpotOn/API/Credentials.pm:68-74` (`%_deriveInflight` queue-or-spawn guard, checked FIRST before rate-limit/binary/token gates) and `:309-318` (`_resolveInflight`, WR-06 eval-guarded per-callback drain so one dying consumer doesn't starve others). Verified this guard is upstream of all three call sites (Settings.pm, DaemonManager.pm ×2) since they all funnel through the single `deriveCredentials` entry point. Secondary claim ("librespot-core atomic write-then-rename as defense-in-depth") references upstream `librespot-core` behavior; the crate is a git dependency (`librespot-spoton/Cargo.toml:20`, not vendored in this repo), so this specific sub-claim cannot be grep-verified against source. Not blocking: the in-repo coalescing lock alone is sufficient to close the concurrent-spawn race this threat describes. |
| T-51-05 | Information Disclosure | low | mitigate (upgraded from `accept` via CR-01) | **CLOSED** | **Perl side:** `Credentials.pm:140-158` — `my $useTokenEnv = Plugins::SpotOn::Helper->getCapability('token-env')`; `@tokenArgs = $useTokenEnv ? () : ('--token', $token)` (argv omitted when capability present); `$ENV{SPOTON_TOKEN} = $token if $useTokenEnv` set immediately before spawn and `delete $ENV{SPOTON_TOKEN} if $useTokenEnv` immediately after (L158), mirroring the existing `SPOTON_LMS_AUTH` pattern in `Daemon.pm`. **Rust side:** `librespot-spoton/src/main.rs:291` advertises `"token-env": true` in the `--check` capability manifest; `main.rs:353-358` reads `SPOTON_TOKEN` from the environment when `--token` argv is empty, with argv retained only as a backward-compat fallback for binaries predating this capability. **Test coverage:** `t/16_credentials.t:639-672` exercises both branches — Test 11 asserts `--token` is absent from spawn args when `token-env` capability is set (L654), Test 11b asserts the argv fallback fires when the capability is absent (L672). `prove t/16_credentials.t` passes (126 total assertions across the three files checked). |
| T-51-06 | DoS | medium | mitigate | **CLOSED** | `Credentials.pm:37-39` (`MAX_DERIVE_FAILURES=3`, `DERIVE_FAILURE_WINDOW=300`, `DERIVE_COOLDOWN_SECONDS=1800`); `_inCooldown` gate (L354-365) is checked in `deriveCredentials` step 2 (L82-86), before any AP contact, short-circuiting with `rate_limited`; `_recordFailure` (L367-391) implements the sliding-window-to-cooldown transition, deliberately excluding pre-flight skips (`no_token`/`no_binary`/`binary_too_old`) from the counter since those never reach the Spotify AP. Reinforced by the WR-01 fix in `DaemonManager.pm:402-417` (`_handleCredentialCrash` checks `TokenManager->needsReauth` and deregisters the dead daemon via `stopHelper` before doing any work), which closes the code-review-identified unbounded 5s crash-poll loop that could otherwise re-invoke `deriveCredentials` indefinitely on a permanently-failed account, outside D-05's own counting logic. |

**Closed: 5/5. Open: 0/5.**

## Cross-Entry-Point Verification

All three `deriveCredentials` call sites route through the single shared module, so every mitigation above (T-51-02 through T-51-06) applies uniformly:

| Call site | File:Line | Purpose |
|-----------|-----------|---------|
| Eager (post-PKCE-auth) | `Settings.pm:528` | Primary user-facing trigger, immediately after OAuth |
| Lazy safety-net | `DaemonManager.pm:561` | Self-heal missing `credentials.json` at daemon start |
| Crash-triggered re-derive | `DaemonManager.pm:441` | D-03 self-heal after a classified credential-rejection crash |

No call site bypasses `deriveCredentials`'s internal gate ordering (coalescing → rate-limit → binary capability → fresh token → spawn → file-based verify → chmod).

## Code Review Cross-Check (51-REVIEW.md)

The review's CR-01 (critical) and four warnings (WR-01 through WR-04) all intersect this phase's threat register. Each fix claimed by the review was independently re-verified in the current on-disk source (not accepted from the review's own prose):

| Review finding | Threat(s) affected | Verified fix location |
|----------------|--------------------|-----------------------|
| CR-01 (token on argv) | T-51-05 | `Credentials.pm:140-158` + `main.rs:291,353-358` (see T-51-05 row above) |
| WR-01 (unbounded crash-poll loop) | T-51-06 | `DaemonManager.pm:402-417` (`needsReauth` check + `stopHelper`) |
| WR-02 (cooldown survives re-auth) | T-51-06 | `Credentials.pm:193-196` (`clearRateLimit`) called from `Settings.pm:527` before every eager `deriveCredentials` |
| WR-03 (stderr misclassification in append mode) | T-51-06 (indirect — prevents false-positive crash-loop entries) | `Daemon.pm:284` (`_stderrStartOffset` recorded at spawn) + `Daemon.pm:538-539` (`stderrTail` bounds reads to `$start`) |
| WR-04 (stale file accepted as fresh success) | T-51-02 | `Credentials.pm:130-136` (`unlink $credFile if -f $credFile` before spawn) |

All five fixes are present in the reviewed source, not merely described as intended.

## Unregistered Flags

None. No `## Threat Flags` section exists in `51-01-SUMMARY.md`, `51-02-SUMMARY.md`, or `51-03-SUMMARY.md` — the executors did not flag any new attack surface requiring a separate threat mapping.

## Regression Verification

`prove t/16_credentials.t t/09_settings.t t/05_perl_syntax.t` — 126 assertions, all passing, confirming the mitigations above are exercised by an executable test suite rather than static code presence alone.

## Accepted Risks Log

None outstanding. T-51-05 was the phase's only `accept`-dispositioned threat at plan time; it was upgraded to `mitigate` and closed via CR-01 before this audit. No threats remain on `accept` or `transfer` disposition in this phase's register.

## Residual / Non-Blocking Notes

- T-51-04's "librespot-core atomic write-then-rename" defense-in-depth claim references behavior in an external git dependency not vendored into this repository, and therefore cannot be grep-verified here. This does not affect the CLOSED status since the primary in-repo mitigation (coalescing) independently closes the threat, but it should be re-verified directly against the `librespot-core` source (or removed from the mitigation plan's wording) if this threat is ever revisited at ASVS L3 depth.
- No `<config>` block (`asvs_level` / `block_on`) was found in `51-01-PLAN.md`; defaults were assumed (see frontmatter). If a project-wide default differs, `threats_open` (currently 0) is unaffected since no threat is OPEN at any severity.

---
*Audited: 2026-07-14*
*Auditor: Claude (gsd-secure-phase)*

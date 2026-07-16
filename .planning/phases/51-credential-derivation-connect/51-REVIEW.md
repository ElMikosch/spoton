---
phase: 51-credential-derivation-connect
reviewed: 2026-07-14T00:00:00Z
depth: deep
files_reviewed: 7
files_reviewed_list:
  - Plugins/SpotOn/API/Credentials.pm
  - Plugins/SpotOn/API/TokenManager.pm
  - Plugins/SpotOn/Settings.pm
  - Plugins/SpotOn/Unified/Daemon.pm
  - Plugins/SpotOn/Unified/DaemonManager.pm
  - t/16_credentials.t
  - t/09_settings.t
findings:
  critical: 1
  warning: 4
  info: 5
  total: 10
status: issues_found
---

# Phase 51: Code Review Report

**Reviewed:** 2026-07-14
**Depth:** deep (cross-module call chains traced, Rust binary contract verified)
**Files Reviewed:** 7
**Status:** issues_found

## Summary

Phase 51 implements PKCE token → librespot stored-credential derivation (`Credentials.pm`), an eager derivation call site after PKCE auth (`Settings.pm`), a lazy safety-net + D-08 mismatch repair in `startHelper`, and a D-03 credential-crash self-heal driven by always-on stderr capture. The async architecture is sound: in-flight coalescing works correctly across eager/lazy/crash callers, the callback queue is drained key-first with eval-guards, the D-05 sliding-window rate limiter is implemented correctly, and log masking discipline is consistently applied in the new code. Both new/extended test files pass (49 + 63 assertions).

However, the review found one security regression against the project's own established hardening standard (access token on subprocess argv, directly contradicting the H10/T-46-01 fix from phase 46), and four correctness/robustness defects in the self-healing loops: an unbounded 5-second crash-handler loop after permanent auth failure, a rate-limit cooldown that survives the very re-auth meant to fix it, stderr-tail misclassification in diagnosticMode append mode, and file-based success detection that cannot distinguish a fresh derivation from a stale pre-existing file.

## Critical Issues

### CR-01: OAuth access token exposed on subprocess argv (world-readable via /proc and ps)

**File:** `Plugins/SpotOn/API/Credentials.pm:127-133`
**Issue:** `deriveCredentials` spawns the helper with the bearer token as a command-line argument:

```perl
Proc::Background->new(
    { 'die_upon_destroy' => 1 },
    $helperPath, '-n', 'SpotOn',
    '--token-login', '--token', $token,
    '--cache', $accountDir,
);
```

On Linux, argv is readable by **any local user** via `/proc/<pid>/cmdline` and `ps`. The token is a Spotify bearer token valid ~1 hour with the account's full scope set (library, playback control, playlists). The exposure window is the subprocess lifetime — a network round-trip to the Spotify AP, up to the 10s poll cap, and repeated on every eager/lazy/crash-recovery derivation.

This directly regresses the project's own security control: phase 46 (commit 31ba2ac, H10/T-46-01) moved LMS credentials off argv into the `SPOTON_LMS_AUTH` env var in `Daemon.pm` **precisely because** "argv is world-readable via /proc/<pid>/cmdline and `ps`" (Daemon.pm:186-189). The T-29-07/T-51-05 comment in Credentials.pm addresses only *logging* the command line, not the /proc exposure. The Rust binary currently accepts the token only via `--token` argv (`librespot-spoton/src/main.rs:31,347`), so this cannot be fixed Perl-side alone.

**Fix:** Add an env-var input to the Rust binary (mirroring the existing `SPOTON_LMS_AUTH` pattern at main.rs:268), advertise it in the `--check` capability manifest, and prefer it in Perl when present:

```perl
# Perl side (Credentials.pm), when capability 'token-env' is present:
$ENV{SPOTON_TOKEN} = $token;
my $proc = eval { Proc::Background->new({...}, $helperPath, '-n', 'SpotOn',
    '--token-login', '--cache', $accountDir) };
delete $ENV{SPOTON_TOKEN};   # immediately after spawn, same as SPOTON_LMS_AUTH
```

```rust
// Rust side (main.rs, Mode::TokenLogin):
if token_str.is_empty() {
    if let Ok(t) = std::env::var("SPOTON_TOKEN") { token_str = t; }
}
```

Keep `--token` argv as fallback for older binaries, but gate on capability so the secure path is used whenever the shipped binary supports it.

## Warnings

### WR-01: Unbounded 5-second crash-handler loop after permanent credential failure

**File:** `Plugins/SpotOn/Unified/DaemonManager.pm:336-351, 397-459`
**Issue:** After `_handleCredentialCrash` escalates via `markNeedsReauth` (or hits the `no_token` branch), nothing stops the loop from re-firing. The dead daemon stays registered in `%helperInstances`, so `_streamAlivePoll` keeps re-arming every 5s (`return unless values %helperInstances` passes). The stderr file still contains the credential-error text (the file is only truncated by the next `start()`, which never happens), so every 5s cycle: `stderrTail` → `isCredentialError` → `_handleCredentialCrash` → WARN log ("deleting credentials.json and re-deriving") → no-op `unlink` → `deriveCredentials` → `getToken` short-circuits on the needsReauth flag → `no_token` → second WARN log. The `no_token` reason is deliberately not counted by D-05 (`_recordFailure`), so the cooldown never engages. Net effect: **~1,700 WARN lines per hour** plus repeated file/cache churn, indefinitely, until the user re-authenticates. The comment "the daemon stays stopped because startHelper's pre-check … and getToken short-circuits" describes the daemon, but not the poll loop that keeps re-entering the handler.

**Fix:** Gate the handler on the re-auth flag before doing any work:

```perl
sub _handleCredentialCrash {
    my ($class, $helper) = @_;
    my $activeAccountId = $prefs->get('activeAccount') || '';
    ...
    require Plugins::SpotOn::API::TokenManager;
    if (Plugins::SpotOn::API::TokenManager->needsReauth($activeAccountId)) {
        # Already escalated — deregister the dead daemon so the 5s poll
        # stops re-classifying the same crash. Re-auth path re-creates it.
        $class->stopHelper($helper->mac);
        return;
    }
    ...
}
```

(`stopHelper` on a dead helper only deletes the registry entry and, when it was the last one, kills the `_streamAlivePoll` timer — exactly the desired quiescent state.)

### WR-02: D-05 cooldown survives a fresh PKCE re-auth, blocking the user's own remediation

**File:** `Plugins/SpotOn/API/Credentials.pm:317-354`, `Plugins/SpotOn/Settings.pm:517-518`
**Issue:** Three `derivation_failed`/`spawn_failed` results within 5 minutes engage a 30-minute per-account cooldown (`%_deriveCooldownUntil`). The only things that clear it are success (`_clearFailures`) or expiry — but during cooldown, `deriveCredentials` short-circuits with `rate_limited` before any attempt, so success is unreachable. When the user then does the one thing the D-08 warning tells them to do — re-authenticate — the eager derivation in `_pkceStoreAccount` instantly resolves `rate_limited`, and the user is shown `PLUGIN_SPOTON_CONNECT_DERIVE_FAILED` ("please retry from the SpotOn settings page") even though their brand-new tokens were never tried. Retrying from Settings is equally blocked. Connect stays down for up to 30 more minutes until the watchdog's lazy path fires post-expiry.

**Fix:** Add a public reset and call it on successful (re-)auth, next to `clearNeedsReauth`:

```perl
# Credentials.pm
sub clearRateLimit {
    my ($class, $accountId) = @_;
    _clearFailures($accountId);
}

# Settings.pm _pkceStoreAccount, before deriveCredentials:
Plugins::SpotOn::API::Credentials->clearRateLimit($accountId);
```

A fresh user-initiated auth is exactly the event D-05's AP-hammering protection should yield to (one attempt with new tokens, not zero).

### WR-03: diagnosticMode append-mode stderr tail misclassifies unrelated crashes as credential errors

**File:** `Plugins/SpotOn/Unified/Daemon.pm:217-222, 517-535`, `Plugins/SpotOn/Unified/DaemonManager.pm:342-345`
**Issue:** With diagnosticMode ON, the `-unified.log` is opened `'>>'` and accumulates across daemon runs. `stderrTail(8192)` reads the last 8KB of the *file*, not of the *current run*. Any daemon death — a panic, an OOM kill, even the port-poll timeout path that deliberately kills the daemon (`Daemon.pm:347`) — will be classified as a credential crash if a "Bad credentials" / "No cached credentials in" line from an **earlier** run is still within the last 8KB (likely, since a crashing run often emits few lines). Consequence chain: valid `credentials.json` deleted → re-derive spawned (token-endpoint POST + AP login) → each unrelated crash burns a derive attempt → three unrelated crashes in 5 minutes push the account into the D-05 cooldown with the credentials file already deleted → Connect down for 30 minutes. Non-diag mode is safe only because `'>'` truncates on each start.

**Fix:** Scope the tail to the current run. Record the file size at spawn time and read only bytes after it:

```perl
# Daemon.pm start(), after open():
$self->_stderrStartOffset($stderr_fh ? (-s $stderrFile || 0) : 0);

# stderrTail():
my $start = $self->_stderrStartOffset || 0;
my $from  = $size - $maxBytes > $start ? $size - $maxBytes : $start;
seek($fh, $from, 0);
```

(Requires adding `_stderrStartOffset` to the accessor list.)

### WR-04: File-based success detection accepts a stale pre-existing credentials.json as a successful derivation

**File:** `Plugins/SpotOn/API/Credentials.pm:250-266`, `Plugins/SpotOn/Settings.pm:518`
**Issue:** `_pollDerivation` decides success solely via `verifyCredentials` — "did a valid-shaped file exist after the subprocess exited". The D-03 and D-08 paths unlink the file before deriving, so they are safe; the **eager Settings path is not**. On re-auth of an existing account, the old `credentials.json` (potentially the very credentials the AP now rejects) is still on disk. If the `--token-login` subprocess fails and writes nothing, `verifyCredentials` finds the old file, and derivation resolves `ok=1`: the user gets `connectReady: 1`, `scheduleInit` starts a daemon on rejected credentials (crash → D-03 detour instead of an honest failure), and — worse — the false success calls `_clearFailures`, resetting the D-05 rate limiter on the basis of a stale file. Note the test suite cannot catch this: t/16 Test 1 ("happy path") *pre-seeds* credentials.json before calling `deriveCredentials` (t/16_credentials.t:357), so the success path is only ever exercised against a pre-existing file.

**Fix:** Make the file the subprocess's output, not a leftover — unlink before spawning (the PKCE tokens, not credentials.json, are the source of truth on this path):

```perl
# deriveCredentials, step 5, before Proc::Background->new:
my $credFile = $class->credentialsPathFor($accountId);
unlink $credFile if -f $credFile;
```

Alternatively compare mtime/size before vs after. Then update t/16 Test 1 to seed the file from a spawn side-effect (e.g. have the Proc::Background stub's `new` write it) so the test verifies fresh-file detection.

## Info

### IN-01: Eager derivation performs a redundant token-endpoint exchange, contradicting its own comment

**File:** `Plugins/SpotOn/Settings.pm:513-518`, `Plugins/SpotOn/API/TokenManager.pm:52-70`
**Issue:** The D-01 comment says derivation happens "while the PKCE access token is guaranteed fresh (it was exchanged seconds ago)" — but that token is never used. `_pkceStoreAccount` persists tokens via `PKCE::storeTokens` without calling `_cacheToken`, so `deriveCredentials` → `getToken` cache-misses and performs a full `refreshAccessToken` round-trip, rotating the refresh token seconds after issuance and adding latency to the user-facing OAuth result page.
**Fix:** Cache the just-exchanged access token in `_pkceStoreAccount` (e.g. via a public `TokenManager->cacheToken($accountId, $tokenData->{access_token}, $tokenData->{expires_in})` wrapper) before calling `deriveCredentials`.

### IN-02: Account dir created with default umask instead of 0700

**File:** `Plugins/SpotOn/API/Credentials.pm:120-124`
**Issue:** `File::Path::make_path($accountDir)` creates the directory 0755 under a typical umask. The Settings eager path chmods 0700 (T-04.3-07 pattern, Settings.pm:501); this path does not. credentials.json itself is chmod 0600, so exposure is limited to directory listing, but it is inconsistent defense-in-depth.
**Fix:** `File::Path::make_path($accountDir, { mode => 0700 });`

### IN-03: No-op killTimers on a freshly created state hashref

**File:** `Plugins/SpotOn/API/Credentials.pm:156`
**Issue:** `Slim::Utils::Timers::killTimers($state, \&_pollDerivation)` can never match anything — `$state` was allocated two lines above and no timer has been set on it. Copied from Daemon.pm's pattern where `$self` persists across starts. Dead code that implies a cancellation guarantee that does not exist.
**Fix:** Remove the line (the in-flight coalescing guard already prevents concurrent polls per account).

### IN-04: Token-leak regression test does not cover INFOLOG-guarded log lines

**File:** `t/16_credentials.t:281-290, 634-641`
**Issue:** Test 12 asserts no captured log line contains the token, but the harness pins `main::INFOLOG` to 0 and `is_info` to 0, so every `main::INFOLOG && $log->info(...)` statement in the module is skipped entirely. A token leak introduced in an info-level line would pass this test. Only warn/error paths are actually covered.
**Fix:** Set `*main::INFOLOG = sub () { 1 }` (and `is_info { 1 }`) in this test file so info-level lines execute and are captured.

### IN-05: Inconsistent accountId masking within `_pkceStoreAccount`

**File:** `Plugins/SpotOn/Settings.pm:489, 506 vs 549`
**Issue:** The new failure branch carefully masks the accountId (`substr($accountId,0,4).'****'`, T-50-01 discipline), while the storage-failure log (line 489) and the success log (line 506) in the same sub log the full accountId. The full-id lines predate this phase, but the new masked line makes the inconsistency visible; the derived 8-char md5 prefix is low-sensitivity, so this is hygiene only.
**Fix:** Mask all three, or use a shared `_mask` helper as in TokenManager/Credentials.

---

_Reviewed: 2026-07-14_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: deep_

# Phase 51: Credential Derivation + Connect - Pattern Map

**Mapped:** 2026-07-14
**Files analyzed:** 6 (1 new module, 5 modified)
**Analogs found:** 6 / 6

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|--------------------|------|-----------|-----------------|----------------|
| `Plugins/SpotOn/API/Credentials.pm` (NEW) | service | request-response (async subprocess + file verify) | `Plugins/SpotOn/API/TokenManager.pm` (`_refreshToken`, in-flight coalescing) + `Plugins/SpotOn/Unified/Daemon.pm` (`_pollPortFile`, async subprocess poll) | role-match (composite: two analogs, one per concern) |
| `Plugins/SpotOn/Unified/DaemonManager.pm` (MODIFIED — `startHelper` lazy hook, crash-handler stderr-error detection) | service/controller | event-driven (watchdog + crash handling) | itself (existing `startHelper` L386-406, account-change detection L410-416) | exact (extending existing file) |
| `Plugins/SpotOn/Unified/Daemon.pm` (MODIFIED — always-on stderr ring buffer regardless of `diagnosticMode`) | service | streaming/file-I/O (subprocess stderr capture) | itself (existing stderr gating L209-221) | exact (extending existing file) |
| `Plugins/SpotOn/Settings.pm` (MODIFIED — `_pkceStoreAccount` eager derivation call site) | controller | request-response | itself (existing `_pkceStoreAccount` L473-520) | exact (extending existing file) |
| `Plugins/SpotOn/API/TokenManager.pm` (MODIFIED — D-08 account-mismatch guard, D-04 re-derive-failure reauth) | service | CRUD | itself (existing `_markNeedsReauth` L446-462, `removeAccount` L75-125) | exact (extending existing file) |
| `t/16_credentials.t` (NEW) | test | request-response (unit, stubbed) | `t/07_token_manager.t` | exact (test-harness convention) |

## Pattern Assignments

### `Plugins/SpotOn/API/Credentials.pm` (NEW — service, async subprocess)

**Analog 1 (subprocess spawn/poll shape):** `Plugins/SpotOn/Unified/Daemon.pm`

**Imports pattern** (Daemon.pm lines 1-17):
```perl
package Plugins::SpotOn::Unified::Daemon;

use strict;
use warnings;

use File::Glob qw(bsd_glob);
use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempfile);
use MIME::Base64 qw(encode_base64);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;
```
Adapt for Credentials.pm: add `use JSON::XS::VersionOneAndTwo;` (credentials.json parse), drop `MIME::Base64`/`File::Temp` (no port tempfile needed), keep `Proc::Background` as a lazy `require` (Daemon.pm requires it inside `start()`, not at top — same convention should be followed).

**Non-blocking spawn + poll pattern** (Daemon.pm lines 248-297, `_pollPortFile` lines 301-364):
```perl
eval {
    $self->_proc( Proc::Background->new(
        { 'die_upon_destroy' => 1, ... },
        $helperPath,
        @helperArgs,
    ) );
};
...
Slim::Utils::Timers::killTimers($self, \&_pollPortFile);
Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollPortFile);

sub _pollPortFile {
    my $self = shift;
    ...
    my $procAlive = $self->_proc && $self->_proc->alive;
    if (!defined $port_line && $procAlive && $attempts < PORT_POLL_MAX_ATTEMPTS) {
        Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollPortFile);
        return;
    }
    # completion (success / death / timeout) handling below
}
```
**Copy this shape exactly** for `deriveCredentials`/`_pollDerivation` (RESEARCH.md's own Pattern 1 code example already adapts it — use that as the primary skeleton, cross-checked against this analog for the timer-kill idiom (`Slim::Utils::Timers::killTimers($self, \&_pollDerivation)` before first `setTimer`) and the "poll again vs. complete" branch structure). Use `->alive == false || attempts >= cap` as the completion trigger (mirrors `!defined $port_line && $procAlive && $attempts < MAX`).

**Analog 2 (in-flight coalescing + async callback resolution):** `Plugins/SpotOn/API/TokenManager.pm::_refreshToken` (lines 254-343)

```perl
my %_refreshInflight;
...
sub _refreshToken {
    my ($class, $accountId, $cb) = @_;

    if ($_refreshInflight{$accountId}) {
        main::INFOLOG && $log->info("TokenManager: coalescing refresh for account " . _mask($accountId));
        push @{ $_refreshInflight{$accountId} }, $cb;
        return;
    }
    $_refreshInflight{$accountId} = [$cb];

    my $resolve = sub {
        my ($token) = @_;
        my $queue = delete $_refreshInflight{$accountId} || [];
        # WR-06: eval-guard each callback — one dying consumer must not starve
        # remaining waiters.
        for my $qcb (@{$queue}) {
            eval { $qcb->($token); 1 }
                or $log->error("TokenManager: refresh callback died: $@");
        }
    };
    ...
}
```
Use this exact shape for Pitfall 3's in-flight guard (`%_deriveInflight` keyed by `$accountId`), including the eval-guarded callback drain (WR-06 pattern — mandatory given the project's own bug history on this exact class of coalescing bug).

**Token-freshness pattern (Pitfall 5 — Lazy path must not read stale tokens directly):** `TokenManager.pm::getToken` (lines 52-70)
```perl
sub getToken {
    my ($class, $accountId, $cb) = @_;
    if ($class->needsReauth($accountId)) {
        $cb->(undef);
        return;
    }
    my $cacheKey = "spoton_token_${accountId}";
    if (my $cached = $cache->get($cacheKey)) {
        $cb->($cached);
        return;
    }
    $class->_refreshToken($accountId, $cb);
}
```
`Credentials::deriveCredentials` should call `Plugins::SpotOn::API::TokenManager->getToken($accountId, $cb)` (NOT `PKCE::loadTokens` directly) to guarantee a fresh, non-expired access_token per RESEARCH.md Pitfall 5.

**Atomic file-write / chmod convention (for verifying/handling `credentials.json` permissions):** `PKCE.pm::storeTokens` (lines 271-302)
```perl
sub storeTokens {
    my ($accountId, $tokenData) = @_;
    my $dir = _accountDir($accountId);
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }
    my $target = catfile($dir, PKCE_TOKEN_FILE);
    my $tmp    = "$target.tmp.$$";
    my $ok = eval {
        open(my $fh, '>', $tmp) or die "open failed: $!";
        print $fh to_json($tokenData);
        close($fh) or die "close failed: $!";
        chmod(0600, $tmp);
        rename($tmp, $target) or die "rename failed: $!";
        1;
    };
    if (!$ok) {
        $log->error("PKCE: storeTokens failed for account $maskedAccount: $@");
        unlink($tmp) if -e $tmp;
        return 0;
    }
    return 1;
}
```
Not directly reused for `credentials.json` (that file is written by the Rust binary, not Perl), but this is the reference convention for `_accountDir($accountId)` path construction and masked-account logging (`substr($accountId, 0, 4) . '****'`) — apply identically in Credentials.pm's `credentialsPathFor`/`_accountDir` helper and all its log lines.

**File-read + JSON-parse pattern (for `verifyCredentials`/`accountMismatch`):** `PKCE.pm::loadTokens` (lines 307-329)
```perl
sub loadTokens {
    my ($accountId) = @_;
    my $target = catfile(_accountDir($accountId), PKCE_TOKEN_FILE);
    return undef unless -f $target;
    my $data = eval {
        open(my $fh, '<', $target) or die "open failed: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        from_json($json);
    };
    if ($@ || !$data) {
        $log->error("PKCE: loadTokens failed for account $maskedAccount: $@");
        return undef;
    }
    return $data;
}
```
Copy this exact read-and-parse shape for `Credentials::verifyCredentials($accountId)` reading `credentials.json`, and for `accountMismatch()` (RESEARCH.md already provides a near-identical draft at RESEARCH.md lines 366-384 — use that draft, cross-checked against this analog's error handling: `eval { ... }` + `$@ || !$data` guard, never trust a partial parse).

---

### `Plugins/SpotOn/Unified/DaemonManager.pm` (MODIFIED — lazy hook + crash-handler stderr detection)

**Analog:** itself — extend existing patterns in-place.

**Lazy safety-net insertion point** (`startHelper`, lines 391-406):
```perl
my $activeAccountId = $prefs->get('activeAccount') || '';
my $cacheDir = $activeAccountId
    ? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
    : catdir($serverPrefs->get('cachedir'), 'spoton');
my $credFile = catfile($cacheDir, 'credentials.json');

if (! -f $credFile) {
    main::INFOLOG && $log->is_info && $log->info(
        "Skipping Unified daemon for $clientId - no cached credentials (expected: $credFile)"
    );
    return;
}
```
Extend this exact `-f $credFile` check: when false AND `activeAccountId` AND `PKCE::loadTokens($activeAccountId)` exists, call `Credentials->deriveCredentials($activeAccountId, sub { ... retry startHelper ... })` instead of returning immediately (per D-01/architecture diagram in RESEARCH.md).

**Account-change / restart-on-mismatch pattern** (lines 410-416) — reuse verbatim for D-07 (already-shipped, no change needed) and as the template for D-08's mismatch-triggered restart:
```perl
if ($helper && $helper->alive && ($helper->_accountId || '') ne $activeAccountId) {
    main::INFOLOG && $log->is_info && $log->info(
        "Account changed for $clientId (was " . ($helper->_accountId || 'none') . ", now $activeAccountId) — restarting daemon"
    );
    $class->stopHelper($clientId);
    $helper = undef;
}
```

**Crash-loop counter pattern to reuse for D-05 rate-limiting** (`Daemon.pm::_checkStartTimes`, lines 366-400ish):
```perl
use constant MAX_FAILURES_BEFORE_DISABLE_DISCOVERY => 3;
use constant MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY => 5 * 60;
use constant DISCOVERY_COOLDOWN_SECONDS => 1800;
...
if ( scalar @{$self->_startTimes} >= MAX_FAILURES_BEFORE_DISABLE_DISCOVERY ) {
    splice @{$self->_startTimes}, 0, @{$self->_startTimes} - MAX_FAILURES_BEFORE_DISABLE_DISCOVERY;
    if ( time() - $self->_startTimes->[0] < MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY ) {
        # ...disable + cooldown...
    }
}
```
Model D-05's re-derive rate limiter on this exact counter+window+cooldown shape (own package-level array or hash keyed by `$accountId`, analogous constants scoped to re-derive attempts).

---

### `Plugins/SpotOn/Unified/Daemon.pm` (MODIFIED — always-capture stderr ring buffer)

**Analog:** itself — current gated stderr handling (lines 209-221):
```perl
my $diagMode = $prefs->get('diagnosticMode');
my $stderrFile;
my $stderr_fh;
if ($diagMode) {
    $stderrFile = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-unified.log');
    open($stderr_fh, '>>', $stderrFile)
        or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderr_fh; undef $stderrFile; };
} else {
    open($stderr_fh, '>', File::Spec->devnull)
        or do { $log->warn("Cannot open /dev/null for stderr: $!"); undef $stderr_fh; };
}
```
Per RESEARCH.md Pitfall 1, this must change so a small ring buffer (last N lines) is ALWAYS captured regardless of `$diagMode`, independent of the full diagnostic log file. Keep the existing `$diagMode` branch for the full verbose log (unchanged), but add an always-on capture path (e.g., a small bounded tempfile or in-memory buffer read by the crash handler) feeding `DaemonManager`'s new `_isCredentialError($stderrText)` check (RESEARCH.md Pattern 2, lines 250-257) — reuse that exact regex:
```perl
sub _isCredentialError {
    my ($stderrText) = @_;
    return $stderrText =~ /Bad credentials|Could not validate credentials|No cached credentials in/;
}
```

**STDERR untie/retie pattern to preserve (do not disturb — mandatory for any Proc::Background spawn touching STDERR):** lines 223-230, 264-265:
```perl
my $had_stderr_tie = defined tied(*STDERR);
untie *STDERR if $had_stderr_tie;
...
tie *STDERR, 'Slim::Utils::Log::Trapper' if $had_stderr_tie;
```

---

### `Plugins/SpotOn/Settings.pm` (MODIFIED — `_pkceStoreAccount` eager derivation call site)

**Analog:** itself — existing account-store callback chain (lines 473-520).

**Insertion point** — the derivation call must be inserted inside the `_storeAccountPrefs` success callback, BEFORE the existing success-page render, per D-06/Pitfall 6:
```perl
require Plugins::SpotOn::API::TokenManager;
Plugins::SpotOn::API::TokenManager->_storeAccountPrefs($accountId, $userId, $displayName, sub {
    main::INFOLOG && $log->is_info && $log->info(
        "Settings: PKCE account $accountId connected (displayName=$displayName)");

    Plugins::SpotOn::API::TokenManager->clearNeedsReauth($accountId);

    if ($isJson) {
        _jsonResponse($httpClient, $response, { status => 'ok', accountId => $accountId });
    } else {
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_SUCCESS'),
            string('PLUGIN_SPOTON_PKCE_SUCCESS'), 0);
    }
});
```
Per D-02/D-06/Pitfall 6: wrap the JSON/page-render branch in a new `Credentials->deriveCredentials($accountId, sub { my $ok = shift; ... })` callback. On success: unconditionally call `Plugins::SpotOn::Unified::DaemonManager->scheduleInit()` (do NOT rely on `_storeAccountPrefs`'s `$needsDaemonStart` conditional — Pitfall 6 explicitly documents this gap for "Add Another Account"/re-auth flows), then render the existing success page. On failure: render a NEW warning string ("Connect not available, please retry" — not yet in `strings.txt`, per RESEARCH.md Open Question 2) instead of the success page, but do not fail the whole account-creation flow (Browse/Search already work via PKCE tokens per Phase 50 — D-02 says warn, not block).

**`_storeAccountPrefs`'s existing conditional daemon-start trigger (to note, not directly reuse — this is the gap Pitfall 6 describes):** `TokenManager.pm` lines 404-417:
```perl
my $needsDaemonStart = !$prefs->get('activeAccount');
unless ($prefs->get('activeAccount')) {
    $prefs->set('activeAccount', $accountId);
}
...
if ($needsDaemonStart) {
    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
}
```

---

### `Plugins/SpotOn/API/TokenManager.pm` (MODIFIED — D-08 mismatch handling wiring, D-04 total-failure reauth)

**Analog:** itself — `_markNeedsReauth` (lines 446-462) is the exact mechanism D-04 says to reuse when auto-re-derive itself fails:
```perl
sub _markNeedsReauth {
    my ($class, $accountId, $reason) = @_;
    $cache->set(REAUTH_FLAG_PREFIX . $accountId, { reason => $reason, ts => time() }, 'never');
    if ($INC{'Plugins/SpotOn/Status.pm'}) {
        Plugins::SpotOn::Status->recordError('error', 'Auth',
            "PKCE refresh failed for account " . _mask($accountId) . " ($reason) — re-authentication required");
    }
    $log->warn("TokenManager: PKCE refresh failed for account " . _mask($accountId) . " — re-authentication required");
}
```
Call this directly (with a new reason string, e.g. `'derivation_failed'`) from Credentials.pm's or DaemonManager's D-03/D-04 flow when re-derive fails after credential-error detection — do not duplicate the 4-channel logic.

**File-removal safety pattern for D-08 mismatch repair (delete ONLY `credentials.json`, not the whole account dir — Anti-Pattern from RESEARCH.md):** contrast with `removeAccount`'s directory-wide `remove_tree` (lines 91-109) which is explicitly the WRONG pattern to copy for D-08:
```perl
# removeAccount (full account removal) — do NOT model D-08 mismatch-repair on this:
File::Path::remove_tree($acctDir, { error => \my $errs });
```
For D-08, use a plain `unlink $credFile` (single file only) — `pkce_tokens.json` in the same directory must survive.

---

### `t/16_credentials.t` (NEW test)

**Analog:** `t/07_token_manager.t` — mirror its LMS-stub harness style (stub `Log::Log4perl::Logger`, `Slim::Utils::Prefs`, `Slim::Utils::Cache`) and add a `Proc::Background` stub for the subprocess-spawn tests. Also add `Plugins/SpotOn/API/Credentials.pm` to `t/05_perl_syntax.t`'s syntax-check list (STATE.md documents this exact convention for `PKCE.pm`).

## Shared Patterns

### Async non-blocking subprocess (never blocking backticks/`system()`)
**Source:** `Plugins/SpotOn/Unified/Daemon.pm` lines 248-297, 301-364 (`start()` + `_pollPortFile`)
**Apply to:** `Credentials.pm::deriveCredentials`/`_pollDerivation` — mandatory, this is Pitfall 2's core anti-pattern warning.

### In-flight coalescing keyed by accountId
**Source:** `Plugins/SpotOn/API/TokenManager.pm` lines 40, 254-276 (`%_refreshInflight`, `_refreshToken`)
**Apply to:** `Credentials.pm`'s new `%_deriveInflight` guard (Pitfall 3).

### Masked account-ID logging
**Source:** `Plugins/SpotOn/API/TokenManager.pm::_mask` (lines 467+), used throughout `PKCE.pm`/`TokenManager.pm` (`substr($accountId, 0, 4) . '****'`)
**Apply to:** All new log lines in `Credentials.pm` — never log full accountId, token, or auth_data values (T-29-07/T-50-01 discipline already enforced project-wide).

### Atomic write-then-rename + chmod 0600/0700
**Source:** `Plugins/SpotOn/API/PKCE.pm::storeTokens` (lines 271-302), `Settings.pm::_pkceStoreAccount` (`chmod(0700, $accountDir)`, line 501)
**Apply to:** Any new Perl-side file writes in this phase (note: `credentials.json` itself is written by the Rust binary, not Perl — this pattern applies only if Credentials.pm writes any auxiliary state file).

### 4-channel re-auth warning (D-04)
**Source:** `Plugins/SpotOn/API/TokenManager.pm::_markNeedsReauth` (lines 446-462)
**Apply to:** Credential-derivation total failure path (re-derive also fails) — call directly, do not reimplement.

### Crash-loop counter + cooldown
**Source:** `Plugins/SpotOn/Unified/Daemon.pm::_checkStartTimes` (lines 366-400+), constants at lines 19-25
**Apply to:** D-05's re-derive rate limiter.

## No Analog Found

None — every file in scope has a strong analog already in the codebase (this phase is pure integration of existing shipped patterns, per RESEARCH.md's own framing: "every hard piece already has a working, shipped implementation elsewhere in this codebase").

## Metadata

**Analog search scope:** `Plugins/SpotOn/API/`, `Plugins/SpotOn/Unified/`, `Plugins/SpotOn/Settings.pm`, `t/`
**Files read directly:** `Plugins/SpotOn/Unified/Daemon.pm` (L1-400), `Plugins/SpotOn/Unified/DaemonManager.pm` (L1-450), `Plugins/SpotOn/API/PKCE.pm` (L195-345), `Plugins/SpotOn/API/TokenManager.pm` (L40-390), `Plugins/SpotOn/Settings.pm` (L423-520)
**Pattern extraction date:** 2026-07-14

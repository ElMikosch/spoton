# Phase 51: Credential Derivation + Connect - Research

**Researched:** 2026-07-14
**Domain:** Perl↔Rust subprocess bridging (LMS plugin ↔ librespot fork), OAuth-token-to-Connect-credential exchange, async daemon lifecycle
**Confidence:** HIGH

## Summary

Phase 51 is almost entirely a **Perl-side integration** phase. The hard technical problem — converting a PKCE access_token into a long-lived librespot Connect credential — is already built, shipped, and spike-validated: `spoton --token-login --token <token> --cache <dir>` is present in the currently-bundled binary (`Plugins/SpotOn/Bin/x86_64-linux/spoton`, confirmed via `--check`: `"token-login":true`, v2.0.11) and was implemented back in "Phase 04.2" of the Rust fork. Spikes 004/005 validated the full chain end-to-end: PKCE token → `credentials.json` (auth_type=1, STORED_SPOTIFY_CREDENTIALS) → Connect device visible in the Spotify app under "In anderen Netzwerken" with working playback control, no mDNS required.

A second major finding changes the D-09 scope: **guest ZeroConf credential-overwrite protection is already implemented in the Rust binary**, not something Phase 51 needs to build. `librespot-spoton/src/unified.rs` (comment: "Phase 14 (Credential Isolation)") constructs a `reconnect_cache` with `credentials_location = None` for every post-startup reconnect (ZeroConf-provided new creds, Spirc death, Browse-triggered reconnect). Since `Cache::save_credentials()` is a no-op without a `credentials_location`, a guest who authenticates via mDNS discovery can control playback for that live session but can **never** overwrite the on-disk `credentials.json`. Phase 51's job for D-09 is to **verify and document** this existing behavior, not implement new guarding logic.

The real Perl-side work is: (1) wire the `--token-login` call into two trigger points (Settings.pm eager path, DaemonManager.pm lazy safety-net) using a **non-blocking** subprocess pattern (the existing spike script used blocking backticks, which is fine for a CLI spike but would freeze LMS's single-threaded event loop in production — Daemon.pm's `_pollPortFile` timer-poll pattern must be reused, not backticks/`system()`); (2) detect credential-rejection distinctly from other daemon-start failures via the exact librespot-core error strings (`"Bad credentials"`, `"Could not validate credentials"`, `"No cached credentials in ... "`) verified against the vendored librespot-core source; (3) close a real gap where **stderr is currently discarded (`/dev/null`) unless `diagnosticMode` is on** — D-03's auto-re-derive trigger cannot read a signal that's being thrown away in the default (non-diagnostic) configuration; (4) handle the pre-PKCE legacy credential path (`{cachedir}/spoton/credentials.json`, no accountId subdirectory) that still exists for users who set up SpotOn via ZeroConf before v3.0.

**Primary recommendation:** Build a shared `Plugins::SpotOn::API::Credentials` (or similar) module with a single `deriveCredentials($accountId, $cb)` entry point used by both Settings.pm (eager) and DaemonManager.pm (lazy); implement it as an async Proc::Background + timer-poll (mirroring `Daemon::_pollPortFile`), never blocking backticks; and change Daemon.pm's stderr handling so the last N lines are always captured to a small ring buffer regardless of `diagnosticMode`, specifically to support D-03/D-05 credential-error detection.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Credential derivation trigger — eager | LMS Plugin Backend (`Settings.pm`) | — | Fires inside the existing async PKCE-completion callback chain (`_pkceStoreAccount`), token is guaranteed fresh |
| Credential derivation trigger — lazy safety-net | LMS Plugin Backend (`DaemonManager.pm`) | — | Extends the existing credential pre-check in `startHelper()` (L391-406) |
| Token→credential exchange (AP handshake) | Playback Engine (`spoton --token-login` subprocess) | Spotify Cloud (Access Point) | Only the Rust binary can perform the auth_type=3→1 exchange; already implemented, spike-validated |
| Credential storage (`credentials.json`) | Storage (local filesystem, `{cachedir}/spoton/{accountId}/`) | — | Same directory `Daemon.pm` already reads with `-c`; written atomically by librespot-core's `Cache::save_credentials()` |
| Connect device registration (Spirc/cloud) | Playback Engine (librespot binary) | Spotify Cloud | No mDNS needed — validated in Spike 005, confirmed "other networks" placement |
| Guest ZeroConf overwrite protection | Playback Engine (Rust, `reconnect_cache` credential isolation) | — | **Already implemented** since fork-internal "Phase 14" — verify, don't rebuild |
| Crash / credential-error detection | LMS Plugin Backend (`DaemonManager.pm`) | Playback Engine (stderr text) | Needs stderr capture independent of `diagnosticMode` — current gap (see Pitfalls) |
| Account mismatch guard (D-08) | LMS Plugin Backend (shared derivation module) | Storage | Compares `credentials.json` username vs. active PKCE account, deletes+re-derives |
| Re-derive rate limiting (D-05) | LMS Plugin Backend (`Daemon.pm`-style crash-loop counter) | — | Reuse `_checkStartTimes`/`MAX_FAILURES_BEFORE_DISABLE_DISCOVERY` pattern |
| 4-channel re-auth warning (D-04) | LMS Plugin Backend (`TokenManager.pm`, `Status.pm`, `Plugin.pm`, `Settings.pm`) | LMS Web UI (OPML + Settings template) | Reuses Phase 50 D-08 infrastructure verbatim |

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUTH-03 | PKCE access token is used once to obtain non-expiring librespot stored credentials (PR #1309 pattern: token → AP session → credential blob) | `spoton --token-login` already implemented and spike-validated (Spike 004); exact invocation, output format, and error strings documented below |
| AUTH-04 | librespot starts with stored credentials + `--disable-discovery` — Connect device appears via cloud/Spirc registration, no mDNS needed | Spike 005 validated end-to-end; `Daemon.pm` already builds `--enable-connect`/`--disable-discovery` flags correctly (L143-180) — no changes needed there, only credential-file availability gates it |
</phase_requirements>

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Two call-sites for credential derivation: (1) Settings-Eager — immediately after PKCE auth completion in Settings.pm (token is guaranteed fresh), (2) DaemonManager-Lazy — safety-net before daemon start when `credentials.json` is missing but PKCE tokens exist. Shared derivation logic in a common module.
- **D-02:** Settings UI feedback: transparent on success ("Account connected"), warning only on derivation failure ("Connect not available, please retry").
- **D-03:** Auto-Re-Derive on daemon crash due to invalid credentials: DaemonManager detects credential error in stderr → deletes `credentials.json` → Lazy-Path triggers re-derivation from PKCE tokens → daemon restart. Transparent for the user.
- **D-04:** When auto-re-derive also fails (PKCE refresh token expired/revoked — 6-month inactivity or Spotify revoke): set needsReauth flag → 4-channel warning (OPML menu, Settings page, Status health panel, Log) from Phase 50 D-08. Daemon stays stopped until user re-authenticates.
- **D-05:** Rate-limiting of re-derive attempts to prevent infinite loops: Claude's discretion on mechanism (existing crash-loop detection pattern available).
- **D-06:** After credential derivation in Settings-Eager path: trigger daemon start immediately (call initHelpers). Connect device appears without delay in the Spotify app.
- **D-07:** If a daemon is already running with old credentials (e.g., ZeroConf → PKCE migration): stop and restart with new PKCE-derived credentials. Leverage existing account-change detection in DaemonManager (L410-416).
- **D-08:** PKCE account is authoritative. On mismatch between `credentials.json` username and PKCE account: delete old `credentials.json`, derive new from current PKCE token. No user confirmation needed.
- **D-09:** Guest ZeroConf protection: ZeroConf discovery MUST NOT overwrite `credentials.json` when PKCE tokens exist for the account. PKCE-derived credentials have precedence over discovery-provided credentials.
- **D-10:** ZeroConf → PKCE migration cleanup scope: Claude's discretion whether cleanup happens in Phase 51 or deferred to Phase 53 (Keymaster Removal + Migration).

### Claude's Discretion

- Rate-limit mechanism for re-derive attempts (D-05)
- Module placement for shared derivation logic (PKCE.pm extension vs new module)
- Internal structure of credential error detection in daemon stderr parsing
- Migration cleanup timing — Phase 51 vs Phase 53 (D-10)

### Deferred Ideas (OUT OF SCOPE)

- **ZeroConf → PKCE full migration UX** — Phase 53 (Keymaster Removal + Migration) handles the broader migration story, including existing user notification and step-by-step guidance
- **Login5 fallback path** (AUTH-06) — Phase 53, not Phase 51
</user_constraints>

## Standard Stack

### Core

No new external dependencies. This phase is pure integration of already-bundled components.

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|---------------|
| `spoton` binary (`--token-login`) | v2.0.11+ (bundled at `Plugins/SpotOn/Bin/x86_64-linux/spoton`) [VERIFIED: local `--check` output] | PKCE access_token → `credentials.json` exchange | Already implemented, spike-validated (Spike 004), only open-source implementation of this exchange |
| `Proc::Background` | LMS-bundled CPAN module | Non-blocking subprocess spawn for `--token-login` | Same module already used by `Daemon.pm` for the long-running daemon; cross-platform (Windows-safe, per project's Windows-compat constraint) |
| `Slim::Utils::Timers` | LMS core | Async poll loop for subprocess completion | Same pattern as `Daemon::_pollPortFile` (M12) — must not block LMS's single-threaded event loop |
| `JSON::XS::VersionOneAndTwo` | LMS-bundled | Parsing `credentials.json` for account-mismatch check (D-08) | Already the standard JSON module throughout the codebase |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Async Proc::Background + timer poll | Blocking backticks (`` `$cmd 2>&1` `` as used in Spike 004's `derive_creds.pl`) | Spike script is fine standalone; in production this blocks LMS's single-threaded reactor for the duration of the subprocess (<1s per spike, but unacceptable in an event-loop server — freezes all players' web UI/audio during that window) |
| Reading stderr for credential-error detection | Adding a new Rust-side structured-error file (like `SPOTON_PORT_FILE`/`SPOTON_TOKEN_FILE`) | Simpler in the short term to grep stderr text (no Rust changes needed); a structured signal file would be more robust but requires a binary rebuild — not justified for Phase 51 scope, revisit if stderr-text matching proves brittle |
| Detecting derivation success via stdout `"credentials_saved"` string | Detecting success via `credentials.json` file existence + exit code | File-existence check is more robust and matches the project's own prior fix history — stdout piping is documented as broken on Windows services (commit `9874835`, `SPOTON_TOKEN_FILE` fix for the unrelated `--get-token` path). Prefer file-based verification for `--token-login` too. |

**No `npm install` / `pip install` equivalent needed** — this is a pure-Perl + already-bundled-Rust-binary integration phase.

## Package Legitimacy Audit

**Not applicable.** This phase installs no new external packages (no new CPAN modules, no new Rust crates, no binary rebuild). All components used (`Proc::Background`, `JSON::XS::VersionOneAndTwo`, `Slim::Utils::Timers`, the `spoton` binary's `--token-login` subcommand) already exist in the codebase and are already exercised by shipped code paths.

## Architecture Patterns

### System Architecture Diagram

```
User completes PKCE OAuth (Phase 49/50, already working)
        │
        ▼
Settings.pm _pkceStoreAccount()  ──(stores pkce_tokens.json, sets activeAccount)──▶ TokenManager::_storeAccountPrefs
        │
        ▼
 [NEW] deriveCredentials($accountId, $cb)  ◀── SHARED MODULE (D-01)
        │
        ├─ loadTokens($accountId) — PKCE.pm, confirm access_token not expired
        │     │
        │     └─ if expired → PKCE::refreshAccessToken() first
        │
        ├─ Proc::Background->new(spoton, '--token-login', '--token', $token, '--cache', $accountDir)
        │     │  (non-blocking spawn; timer-poll for completion, mirrors Daemon::_pollPortFile)
        │     ▼
        │  spoton --token-login  ──▶  Spotify AP (access point)
        │     │                         returns reusable_auth_credentials (auth_type=1)
        │     ▼
        │  credentials.json written to {cachedir}/spoton/{accountId}/  (atomic, librespot-core internal)
        │
        └─ poll: Proc::Background->alive == false  →  check exit code + credentials.json exists + auth_type==1
              │
              ├─ success ──▶ $cb->(1)  ──▶ Settings.pm: "Account connected" (D-02)
              │                          ──▶ DaemonManager->scheduleInit() / initHelpers (D-06)
              │
              └─ failure ──▶ $cb->(0)  ──▶ Settings.pm: "Connect not available, please retry" (D-02)

Lazy safety-net path (DaemonManager::startHelper, credential pre-check L391-406):
        │
        ▼
 credentials.json missing? ──yes──▶ PKCE::loadTokens($accountId) exists? ──yes──▶ deriveCredentials(...) ──▶ retry startHelper
                                                                          ──no───▶ skip daemon start (existing behavior, unchanged)

Crash-loop auto-re-derive path (D-03, NEW — requires stderr capture independent of diagnosticMode):
        │
Daemon crashes / --unified exits 1
        │
        ▼
 stderr contains "Login failed with reason: Bad credentials"
              or "Could not validate credentials"           ──▶ credential error detected
        │
        ▼
 delete credentials.json  ──▶  deriveCredentials($accountId, $cb)  ──▶ restart daemon
        │                                    │
        │                                    └─ fails ──▶ TokenManager::_markNeedsReauth (D-04, reuses Phase 50 4-channel warning)
        ▼
 rate-limited via crash-loop counter (D-05, reuse Daemon::_checkStartTimes pattern)

Connect registration (already working, no changes needed — AUTH-04):
        │
 spoton --unified --enable-connect [--disable-discovery] -c {accountDir}
        │
        ▼
 Spirc cloud registration ──▶ Spotify app shows device under "In anderen Netzwerken" (Spike 005 validated)

Guest ZeroConf protection (already implemented — D-09, verify only):
        │
 librespot ZeroConf discovery receives new creds from a LAN guest
        │
        ▼
 reconnect_cache (credentials_location = None) used for the reconnect session
        │
        ▼
 in-memory session uses guest creds; on-disk credentials.json is NEVER touched
        (unified.rs comment: "Phase 14 (Credential Isolation)")
```

### Recommended Module Structure

```
Plugins/SpotOn/API/
├── PKCE.pm                    # existing — token storage/refresh (Phase 49/50)
├── TokenManager.pm            # existing — token cache, needsReauth (Phase 50)
└── Credentials.pm             # NEW — shared derivation module (D-01)
    ├── deriveCredentials($accountId, $cb)      # async, calls --token-login
    ├── credentialsPathFor($accountId)          # single source of truth for the file path
    ├── verifyCredentials($accountId)           # parse credentials.json, check auth_type==1 + username
    └── accountMismatch($accountId)             # D-08: compare stored username vs PKCE account
```

Placement rationale: `PKCE.pm` owns Web-API-token concerns (access/refresh tokens, scopes, OAuth endpoints). Credential derivation is a *distinct* concern (subprocess management, `credentials.json` parsing, librespot-fork contract) consumed by both `Settings.pm` and `DaemonManager.pm` — a new module avoids `DaemonManager.pm` (already 700+ lines) `require`-ing `Settings.pm`-adjacent logic and keeps the Proc::Background subprocess pattern isolated and testable (matches the existing `t/07_token_manager.t` stub-based test style).

### Pattern 1: Non-Blocking One-Shot Subprocess (adapt from `Daemon::_pollPortFile`)

**What:** Spawn a short-lived subprocess (`--token-login`) via `Proc::Background`, then poll for completion on an LMS timer instead of blocking.
**When to use:** Any one-shot binary invocation from within LMS's single-threaded event loop (this pattern already exists for the long-running daemon's port announcement; the same shape applies to a short-lived subprocess, just polling `->alive` instead of a tempfile).
**Example (adapted from verified `Daemon.pm` L292-364 pattern; do NOT use backticks/`system()` as the spike script does):**
```perl
# Source: pattern adapted from Plugins/SpotOn/Unified/Daemon.pm _pollPortFile (M12)
sub deriveCredentials {
    my ($class, $accountId, $cb) = @_;

    require Plugins::SpotOn::API::PKCE;
    my $tokens = Plugins::SpotOn::API::PKCE::loadTokens($accountId);
    return $cb->(0, 'no_pkce_tokens') unless $tokens && $tokens->{access_token};

    my $accountDir = catdir(preferences('server')->get('cachedir'), 'spoton', $accountId);
    require Plugins::SpotOn::Helper;
    my $helperPath = Plugins::SpotOn::Helper->get();
    return $cb->(0, 'no_binary') unless $helperPath;

    require Proc::Background;
    my $proc = eval {
        Proc::Background->new(
            { die_upon_destroy => 1 },
            $helperPath, '-n', 'SpotOn',
            '--token-login', '--token', $tokens->{access_token},
            '--cache', $accountDir,
        );
    };
    return $cb->(0, 'spawn_failed') if $@ || !$proc;

    _pollDerivation($proc, $accountDir, $cb, 0);
}

sub _pollDerivation {
    my ($proc, $accountDir, $cb, $attempts) = @_;

    if ($proc->alive && $attempts < 50) {   # 5s cap at 0.1s interval
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.1,
            \&_pollDerivation, $proc, $accountDir, $cb, $attempts + 1);
        return;
    }

    # Verify via file, not stdout (Windows stdout-piping is documented as
    # broken for subprocess output — see SPOTON_TOKEN_FILE fix, commit 9874835).
    my $credFile = catfile($accountDir, 'credentials.json');
    my $ok = -f $credFile && do {
        my $data = eval { local $/; open my $fh, '<', $credFile or die; from_json(<$fh>) };
        !$@ && $data && ($data->{auth_type} // -1) == 1 && $data->{username};
    };
    $cb->($ok ? 1 : 0, $ok ? undef : 'derivation_failed');
}
```

### Pattern 2: Credential-Error Detection in stderr (D-03) — exact strings verified against librespot-core source

**What:** Distinguish "credentials rejected/invalid" from other daemon-start failures in the `spoton --unified` stderr output.
**When to use:** `DaemonManager`'s crash handler, before deciding to auto-re-derive vs. treat as a generic crash.
**Verified error strings** (from `~/.cargo/git/checkouts/librespot-*/core/src/connection/mod.rs::login_error_message()` and `librespot-spoton/src/main.rs` error propagation):

| Condition | Exact stderr substring | Source |
|-----------|------------------------|--------|
| `credentials.json` missing entirely | `No cached credentials in '<dir>'. Run --authenticate or --discover-once first.` | `unified.rs` L1254 → `main.rs` L416-418 (`"Unified mode error: {}", e`) |
| Stored credentials rejected by Spotify AP | `Login failed with reason: Bad credentials` | `login_error_message()`, `ErrorCode::BadCredentials` |
| Stored credentials fail validation | `Login failed with reason: Could not validate credentials` | `login_error_message()`, `ErrorCode::CouldNotValidateCredentials` |
| `--token-login` itself fails (used during derivation, not daemon start) | `Token login failed: <inner error>` | `main.rs` L363 |

```perl
# Source: verified against Plugins/SpotOn/Unified/Daemon.pm stderr capture +
# librespot-core connection/mod.rs::login_error_message()
sub _isCredentialError {
    my ($stderrText) = @_;
    return $stderrText =~ /Bad credentials|Could not validate credentials|No cached credentials in/;
}
```

**Critical gap this exposes:** `Daemon.pm` (L209-221) only opens a real stderr file handle when `$prefs->get('diagnosticMode')` is true; otherwise stderr is redirected to `File::Spec->devnull`. In the **default** (non-diagnostic) configuration — which is how most users run SpotOn — this detection has **nothing to read**. See Pitfall 1.

### Anti-Patterns to Avoid

- **Blocking the LMS event loop with backticks or `system()`** for `--token-login` — the spike script (`derive_creds.pl`) does this deliberately for a one-shot CLI tool; production Settings.pm/DaemonManager.pm code must not, since LMS is single-threaded and this would freeze all connected players during the (sub-second, but non-zero) subprocess run.
- **Parsing stdout for `"credentials_saved"`** as the success signal — the project has already hit and fixed a Windows-specific stdout-piping bug for a structurally identical case (`--get-token`, commit `9874835`, `SPOTON_TOKEN_FILE`). Prefer file-existence + `auth_type` verification (Pattern 1 above), which works identically on all platforms.
- **Re-implementing guest ZeroConf overwrite protection in Perl** — this is already solved at the Rust layer (`reconnect_cache` credential isolation). Perl-side work for D-09 should be a verification/documentation task, not new guard code.
- **Deleting the whole account directory for D-08 mismatch** — only `credentials.json` is stale; `pkce_tokens.json` for that same `accountId` is still valid and must be preserved. Use `unlink $credFile`, not `File::Path::remove_tree($accountDir)` (that pattern is `TokenManager::removeAccount`'s, used for full account removal, not credential mismatch repair).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|--------------|-----|
| PKCE access_token → Connect credential exchange | A custom AP-handshake implementation in Perl | `spoton --token-login` (already built, spike-validated) | librespot's AP protocol (double-connect, `reusable_auth_credentials`) has no Perl equivalent and shouldn't be reimplemented — it's already correctly implemented in the Rust fork |
| Guest-discovery credential-overwrite protection | Perl-side pre-write interception of `credentials.json` | Rust-side `reconnect_cache` credential isolation (already shipped) | Any Perl-side file-watching/locking approach would race with the Rust binary's own atomic writes; the existing solution operates at the source (never attempts the write) rather than reactively guarding a file |
| Async subprocess completion signaling | A new polling/notification mechanism | `Slim::Utils::Timers` + `Proc::Background->alive` (same shape as `Daemon::_pollPortFile`) | The codebase already solved "wait for a short-lived Rust subprocess without blocking LMS" for port announcement — reuse the shape, don't invent a second one |
| Crash-loop rate limiting for re-derive attempts | A new counter/cooldown mechanism | `Daemon::_checkStartTimes` / `MAX_FAILURES_BEFORE_DISABLE_DISCOVERY` pattern | Directly analogous problem (repeated daemon-start failures within a time window) already solved with a tunable threshold + cooldown timer |
| Multi-channel re-auth notification | New notification plumbing | `TokenManager::_markNeedsReauth` (Phase 50 D-08, OPML + Settings + Status + Log) | Exact same signal ("user must re-authenticate") — D-04 explicitly says to reuse this |

**Key insight:** Every "hard" piece of this phase (AP handshake, guest-overwrite protection, async subprocess polling, crash-loop backoff, re-auth notification) already has a working, shipped implementation elsewhere in this codebase or fork. Phase 51's actual net-new code is thin: one shared derivation module, two call sites, and a stderr-capture fix.

## Runtime State Inventory

> Included because this phase involves ZeroConf → PKCE credential migration (D-07, D-08, D-10) touching existing on-disk runtime state, not just new code.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **Legacy flat-dir `credentials.json`** at `{cachedir}/spoton/credentials.json` (no accountId subdirectory) — written by the pre-v3.0 ZeroConf `--discover-once` flow for any user who set up SpotOn before the PKCE migration. `Daemon.pm` L106-111 already falls back to this path when `activeAccountId` is empty (`my $cacheDir = $activeAccountId ? catdir(...,'spoton',$activeAccountId) : catdir(...,'spoton');`). Phase 51's account-mismatch guard (D-08) and derivation logic must be aware that this legacy path exists **in addition to** the new per-account paths — a user with an old flat-dir `credentials.json` who then completes PKCE auth ends up with a `credentials.json` in `{cachedir}/spoton/{accountId}/` (new) while the old flat-dir file remains untouched (orphaned, not deleted by anything). | Code edit: derivation/mismatch logic must operate exclusively on the account-scoped path (matches `Daemon.pm`'s post-PKCE behavior once `activeAccountId` is set). Data migration: decide (per D-10 discretion) whether Phase 51 deletes the orphaned flat-dir file or leaves it for Phase 53's broader migration UX. |
| Live service config | None — no external service (n8n, Datadog, etc.) stores SpotOn credential state outside this repo/filesystem for this phase. | None. |
| OS-registered state | None — no Task Scheduler/launchd/systemd/pm2 entries reference per-account credential paths. | None. |
| Secrets/env vars | `pkce_tokens.json` (Phase 49/50) and `credentials.json` (this phase) are both per-account files under `{cachedir}/spoton/{accountId}/`, already `chmod 0600`/`0700` per existing PKCE.pm/Settings.pm conventions. No env var renaming involved — `SPOTON_LMS_AUTH`/`SPOTON_PORT_FILE` env vars (Daemon.pm) are unrelated to Spotify credentials and untouched by this phase. | None — new code must follow the same chmod convention (`PKCE::storeTokens` pattern: write-then-rename, `chmod 0600` before `rename`). |
| Build artifacts | None — `spoton --token-login` already exists in the bundled binary (`Plugins/SpotOn/Bin/x86_64-linux/spoton`, `--check` confirms `"token-login":true`, v2.0.11). No Rust rebuild required for this phase. | None. |

## Common Pitfalls

### Pitfall 1: stderr is discarded by default — breaks D-03 auto-re-derive detection

**What goes wrong:** `Daemon.pm` (L209-221) only opens a real stderr log file when `$prefs->get('diagnosticMode')` is truthy; otherwise stderr goes to `File::Spec->devnull`. Since `diagnosticMode` defaults off, the exact error strings needed for D-03 detection (`"Bad credentials"`, `"Could not validate credentials"`) are silently thrown away for the vast majority of installations.
**Why it happens:** `diagnosticMode` gating was designed (T-29-09) to avoid unbounded log growth for a *diagnostics* feature, not to gate a *functional* signal the crash-handling logic now needs.
**How to avoid:** Always capture at minimum the last N lines of stderr to a small ring buffer (in memory, or a small bounded tempfile that's overwritten on each start) regardless of `diagnosticMode`. This is cheap (a handful of short lines, not full verbose logging) and independent of the diagnostic-logging feature. Do NOT gate D-03's detection capability behind the diagnosticMode user preference — that would make auto-re-derive a diagnostic-mode-only feature, defeating D-03's "transparent for the user" requirement.
**Warning signs:** If D-03's crash-handler code path is only exercised in tests with `diagnosticMode => 1`, it will silently never fire in production for the default configuration.

### Pitfall 2: Blocking subprocess calls freeze LMS's single-threaded event loop

**What goes wrong:** The validated spike pattern (`derive_creds.pl`) uses blocking backticks (`` `$cmd 2>&1` ``). Copying this pattern directly into `Settings.pm`/`DaemonManager.pm` would block LMS's single-threaded reactor for the subprocess's runtime (sub-second per spike measurements, but still a full-server freeze — every connected player's UI and audio streaming stalls).
**Why it happens:** The spike script is a standalone CLI tool with no event loop to protect; production LMS plugin code runs inside one.
**How to avoid:** Use `Proc::Background` + `Slim::Utils::Timers` polling (Pattern 1 above), mirroring the already-shipped `Daemon::_pollPortFile` (M12) design.
**Warning signs:** Any `` `...` `` backtick invocation or `system()` call of the `spoton` binary inside Settings.pm/DaemonManager.pm/a new Credentials.pm — should be a code-review red flag.

### Pitfall 3: Racing Eager and Lazy derivation for the same account

**What goes wrong:** The 60s `initHelpers` watchdog cycle (`DaemonManager.pm` L310) re-evaluates all daemons, including calling `startHelper()`'s credential pre-check. If a user completes PKCE auth (triggering Eager derivation) at nearly the same moment the watchdog cycle runs (finding no `credentials.json` yet, triggering Lazy derivation), two `--token-login` subprocesses could be spawned concurrently for the same account.
**Why it happens:** No in-flight guard exists yet for derivation (unlike `TokenManager`'s `%_refreshInflight` coalescing for token refresh, T-50 H3).
**How to avoid:** Add an in-flight guard keyed by `$accountId` in the shared derivation module (same shape as `TokenManager::_refreshInflight`) — queue concurrent callers, resolve them all when the single in-flight derivation completes.
**Warning signs:** Two `spoton --token-login` processes visible in `ps` for the same account directory within the same few-hundred-ms window.

### Pitfall 4: Legacy flat-dir credentials confuse the account-mismatch guard (D-08)

**What goes wrong:** If D-08's mismatch-detection logic reads `credentials.json` from the wrong path (flat `{cachedir}/spoton/` instead of the account-scoped `{cachedir}/spoton/{accountId}/`), it could compare against a stale, pre-migration ZeroConf identity that has nothing to do with the current PKCE account, triggering spurious "delete and re-derive" cycles or, worse, silently doing nothing because the compared paths never intersect.
**Why it happens:** Two credential-directory conventions coexist during the ZeroConf→PKCE transition (see Runtime State Inventory).
**How to avoid:** All new derivation/mismatch code must use the account-scoped path exclusively (`catdir($cachedir, 'spoton', $accountId)`), matching `Daemon.pm`'s own post-PKCE behavior. Never read/write the flat-dir path from new code.
**Warning signs:** A user who previously used ZeroConf reports their Connect device keeps reappearing/disappearing after switching to PKCE.

### Pitfall 5: Token expiry during the Lazy (safety-net) derivation path

**What goes wrong:** `--token-login` requires a non-expired access_token (1h TTL per PKCE.pm). The Lazy path fires from `DaemonManager::startHelper`, which could run long after the last token refresh (e.g., right after an LMS restart, before the 45-minute `TokenManager::refreshAllTokens` cycle has run).
**Why it happens:** Nothing currently guarantees token freshness at the Lazy trigger point — Eager derivation is safe by construction (fires right after OAuth), but Lazy is not.
**How to avoid:** The shared derivation module should call `TokenManager->getToken($accountId, $cb)` (which already checks cache-then-refreshes) to obtain a guaranteed-fresh access_token before invoking `--token-login`, rather than reading `pkce_tokens.json` directly and risking a stale token.
**Warning signs:** `--token-login` fails intermittently only on the Lazy path, particularly shortly after LMS restarts.

### Pitfall 6: D-06's "trigger daemon start immediately" doesn't happen automatically for non-first accounts

**What goes wrong:** `TokenManager::_storeAccountPrefs` (called by `_pkceStoreAccount`) only calls `DaemonManager->scheduleInit()` when `$needsDaemonStart` is true, i.e., only for the very first account ever configured. For "Add Another Account" or D-08 mismatch-repair re-auth flows, `activeAccount` is already set, so this conditional branch is skipped — meaning D-06's "Connect device appears without delay" would silently not happen unless the new derivation call site explicitly triggers `initHelpers`/`scheduleInit` itself.
**Why it happens:** `_storeAccountPrefs`'s `scheduleInit` call predates PKCE credential derivation and was only ever meant to bootstrap the very first daemon start.
**How to avoid:** The derivation success callback (wherever it's invoked from Settings.pm) must unconditionally call `DaemonManager->scheduleInit()` (or `initHelpers` directly) after a successful derivation, not rely on `_storeAccountPrefs`'s conditional.
**Warning signs:** Re-authenticating an already-active account, or adding a second account, doesn't bring up a Connect device until the next 60s watchdog cycle.

## Code Examples

### Exact `--token-login` invocation contract (verified against `main.rs` L456-474 and Spike 004)

```perl
# Source: librespot-spoton/src/main.rs run_token_login() (verified in-repo)
my @cmd = ($helperPath, '-n', 'SpotOn',
    '--token-login',
    '--token', $accessToken,     # must be a fresh, non-expired PKCE access_token
    '--cache', $accountDir,      # {cachedir}/spoton/{accountId} — same dir Daemon.pm reads with -c
);
# stdout on success: "credentials_saved" (do not rely on this for cross-platform verification — see Pitfall/Anti-Pattern above)
# exit code 0 = success, credentials.json written to $accountDir
# exit code 1 + stderr "Token login failed: <reason>" = failure
```

### `credentials.json` format (verified via Spike 004 + `main.rs`)

```json
{
  "username": "3fiqdghdkdx37cnnuv1vemc1n",
  "auth_type": 1,
  "auth_data": "QWdDR2VIeW1rOTRJX0tCY2dxcEtPRm..."
}
```
- `auth_type: 1` = `STORED_SPOTIFY_CREDENTIALS` — the ONLY value D-08's mismatch check and derivation-success verification should accept.
- `username` = Spotify user ID (not display name) — this is what D-08 compares against the active PKCE account's `spotifyUserId`.

### D-08 account-mismatch detection

```perl
# Source: pattern derived from credentials.json format (Spike 004) +
# Plugins/SpotOn/API/TokenManager.pm accounts pref structure
sub accountMismatch {
    my ($class, $accountId) = @_;

    my $credFile = catfile(_accountDir($accountId), 'credentials.json');
    return 0 unless -f $credFile;

    my $creds = eval { local $/; open my $fh, '<', $credFile or die; from_json(<$fh>) };
    return 0 if $@ || !$creds || !$creds->{username};

    require Plugins::SpotOn::API::TokenManager;
    my $accounts = preferences('plugin.spoton')->get('accounts') || {};
    my $expectedUserId = $accounts->{$accountId} ? $accounts->{$accountId}{spotifyUserId} : undef;

    return ($expectedUserId && $creds->{username} ne $expectedUserId) ? 1 : 0;
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|---------------|--------|
| ZeroConf `--discover-once` as the sole credential-acquisition path | PKCE OAuth → `--token-login` derivation, with ZeroConf demoted to a guest-discovery *feature* (not an auth mechanism) | v3.0 Auth Overhaul (2026-07, Phases 49-53) | Solves Keymaster's death (403s since Aug 2025), Docker mDNS issues (#103), and rate-pool fragmentation in one architectural move (per STATE.md decision log) |
| Keymaster (`hm://keymaster/token/authenticated`) for Web API tokens | PKCE refresh flow (pure Perl, no binary spawn) — Phase 50, already shipped | Phase 50 (completed prior to this phase) | Not directly this phase's concern, but confirms the general direction: minimize binary spawns, prefer Perl-native async flows where possible — Phase 51's derivation is the one case that *must* spawn the binary (only the Rust binary can do the AP handshake) |

**Deprecated/outdated:**
- `--get-token` (Keymaster path) — scheduled for removal in Phase 53, not touched by Phase 51. Do not model the new derivation module's error-handling on `TokenManager::_fetchKeymasterToken`'s patterns (that's Bucket 1 in `keymaster-audit.md`, being deleted).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The currently-bundled binary version deployed to end users (via the CI-built release artifacts, not the local dev copy inspected here) also has `token-login` capability and the same `reconnect_cache` credential-isolation behavior. Verified locally against `Plugins/SpotOn/Bin/x86_64-linux/spoton` (v2.0.11, `--check` confirms `token-login:true`) and against the checked-in Rust source (`unified.rs`, `main.rs`) — not against the actual release binary users have installed. | Summary, Standard Stack | If a user's installed binary predates "Phase 04.2"/"Phase 14" (very old release), `--token-login` would fail with "unrecognized argument" and D-09's guest-protection would not exist — low risk since binary version is normally kept current via SpotOn's release process, but worth a version-floor check (`Helper::helperCheck` already does `MIN_BINARY_VERSION` comparison — this phase's plan should consider bumping `MIN_BINARY_VERSION` or adding a capability check for `token-login`/`reconnect_cache` if a version boundary is known). |
| A2 | The exact stderr strings (`"Bad credentials"`, `"Could not validate credentials"`) are stable across librespot-core versions — verified against the currently vendored `~/.cargo/git/checkouts/librespot-*` source, which is what `librespot-spoton`'s `Cargo.toml` pins. | Common Pitfalls, Code Examples | If a future librespot-core upgrade changes these strings, D-03's stderr-matching regex would silently stop firing — low likelihood within Phase 51's timeframe since no librespot-core upgrade is planned, but the plan should reference this specific research finding so a future librespot-core bump triggers a recheck of these strings. |

**If this table is empty:** N/A — two low-risk assumptions logged above.

## Open Questions

1. **Should Phase 51 also delete the orphaned legacy flat-dir `credentials.json`?**
   - What we know: `Daemon.pm` already falls back to the flat-dir path only when `activeAccountId` is unset; once a PKCE account is active, the flat-dir file becomes dead weight, never read or written by any current code path.
   - What's unclear: Whether deleting it in Phase 51 (opportunistically, e.g., during D-08's mismatch-repair flow) or deferring cleanup entirely to Phase 53's broader migration UX is preferable.
   - Recommendation: This maps directly to D-10 ("Claude's Discretion"). Given Phase 51's scope is already substantial (new module, two trigger points, stderr-capture fix), recommend deferring the flat-dir cleanup to Phase 53 and scoping Phase 51 strictly to the account-scoped path — Phase 53 already owns "Migration UX for existing ZeroConf users to PKCE" per the ROADMAP.

2. **Does D-02's "Account connected" success message need a new i18n string, or does the existing `PLUGIN_SPOTON_PKCE_SUCCESS` ("Spotify account connected successfully!") suffice?**
   - What we know: `PLUGIN_SPOTON_PKCE_SUCCESS` currently fires at the end of the OAuth token-exchange step (`_pkceStoreAccount`), *before* credential derivation exists as a concept in the codebase — it currently conflates "OAuth succeeded" with "fully Connect-ready."
   - What's unclear: Whether product intent (D-02) wants a single combined success message (reuse existing string, fire it only after derivation also succeeds) or two distinct messages (OAuth succeeded vs. Connect-ready).
   - Recommendation: Given D-02 explicitly says "transparent on success" (implying a single, unified user-facing signal, not a two-step narration), recommend reusing `PLUGIN_SPOTON_PKCE_SUCCESS` but moving its trigger point to fire only after `deriveCredentials()` succeeds, and adding a *new* string only for the failure case ("Connect not available, please retry" — D-02's exact wording, not yet in `strings.txt`).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| `spoton` binary with `--token-login` | Credential derivation (both Eager and Lazy paths) | ✓ [VERIFIED: local `--check`] | v2.0.11 (bundled), source confirms `token-login: true` capability | `Helper::getCapability('token-login')` — not currently queried anywhere; consider adding a capability gate analogous to the existing `getCapability('autoplay')`/`getCapability('passthrough')` checks in `Daemon.pm`, so an out-of-date binary degrades gracefully (shows "please update the SpotOn binary" rather than a cryptic subprocess failure) |
| `Proc::Background` | Non-blocking subprocess spawn | ✓ (LMS-bundled, already imported in `Daemon.pm`) | n/a (CPAN bundled module) | — |
| `Slim::Utils::Timers` | Async completion polling | ✓ (LMS core) | n/a | — |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** `--token-login` capability check is not currently gated — recommend the plan add a `Helper::getCapability('token-login')` check (mirroring existing capability-gating patterns) as a defensive measure, not because it's currently missing.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Custom `Test::More` + hand-written LMS-stub harness (Perl `prove`), no external test framework |
| Config file | none — `t/*.t` files are self-contained, each writing its own LMS-module stubs into a `tempdir()` (see `t/07_token_manager.t` pattern) |
| Quick run command | `prove t/07_token_manager.t` (or a new `t/16_credentials.t`) |
| Full suite command | `prove t/` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|---------------------|--------------|
| AUTH-03 | `deriveCredentials()` writes `credentials.json` with `auth_type==1` given valid PKCE tokens | unit (stubbed `Proc::Background`/binary) | `prove t/16_credentials.t -x` | ❌ Wave 0 |
| AUTH-03 | Lazy path: `startHelper()` triggers derivation when `credentials.json` missing but PKCE tokens exist | unit (stub `DaemonManager`) | `prove t/16_credentials.t -x` | ❌ Wave 0 |
| AUTH-03 | D-08 account-mismatch detection deletes stale `credentials.json` and re-derives | unit | `prove t/16_credentials.t -x` | ❌ Wave 0 |
| AUTH-03 | D-03 stderr credential-error regex matches the exact librespot-core strings documented above | unit (string-matching only, no subprocess needed) | `prove t/16_credentials.t -x` | ❌ Wave 0 |
| AUTH-04 | `--enable-connect`/`--disable-discovery` flag construction unaffected by this phase | regression (existing) | `prove t/10_stream_metadata.t -x` | ✅ existing |
| AUTH-04 | Connect device registration + playback (end-to-end, requires real Spotify account) | manual-only (justification: requires live Spotify Connect handshake and the Spotify app, not mockable in the `t/` harness) | — | n/a |

### Sampling Rate
- **Per task commit:** `prove t/16_credentials.t`
- **Per wave merge:** `prove t/`
- **Phase gate:** Full suite green before `/gsd-verify-work`; manual UAT for AUTH-04 end-to-end Connect registration + playback (real Spotify account required — the `pi-playback-test` / `spoton-uat` project skills exist for this).

### Wave 0 Gaps
- [ ] `t/16_credentials.t` — new test file covering the shared derivation module (mirror `t/07_token_manager.t`'s stub style: stub `Log::Log4perl::Logger`, `Slim::Utils::Prefs`, `Slim::Utils::Cache`, `Proc::Background`)
- [ ] Add `Plugins/SpotOn/API/Credentials.pm` (or chosen module name) to `t/05_perl_syntax.t`'s syntax-check list — matches the existing convention noted in STATE.md ("Added PKCE.pm to t/05_perl_syntax.t syntax-check list")

*(No other gaps — existing `t/07_token_manager.t`, `t/10_stream_metadata.t` infrastructure covers the surrounding token/daemon-lifecycle behavior this phase touches.)*

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|----------------|---------|-------------------|
| V2 Authentication | yes | PKCE access_token is the sole input to credential derivation; token freshness enforced via `TokenManager->getToken` (cache-or-refresh), never a stale on-disk read (Pitfall 5) |
| V3 Session Management | yes | `credentials.json` IS the long-lived Connect session credential — file permissions (`chmod 0600`/`0700`, matching existing `PKCE::storeTokens`/`Settings::_pkceStoreAccount` convention) are the access control; no new session-token format introduced |
| V4 Access Control | yes | D-08's account-mismatch guard prevents credential confusion across accounts; D-09's (already-implemented, Rust-side) guest-overwrite protection prevents a LAN guest from hijacking the primary account's on-disk credentials |
| V5 Input Validation | yes | Derived `credentials.json` must be validated (`auth_type==1`, non-empty `username`/`auth_data`) before being trusted as "derivation succeeded" — never trust exit-code-0 alone (a corrupted/truncated write could still exit 0 in edge cases) |
| V6 Cryptography | no (delegated) | No new cryptography introduced by this phase — the AP handshake and credential-blob encoding are entirely internal to librespot-core, already audited in the upstream project. SpotOn's Perl side never touches key material, only opaque base64 blobs it writes to disk with restrictive permissions. |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|-----------------------|
| Guest on LAN hijacks the primary account's Connect credential via ZeroConf discovery | Spoofing / Tampering | Already mitigated at the Rust layer — `reconnect_cache` strips `credentials_location`, so ZeroConf-provided credentials are used in-memory only, never persisted (D-09 verify-only) |
| Stale/corrupted `credentials.json` silently accepted as "derivation succeeded" | Tampering | Validate `auth_type==1` + non-empty `username`/`auth_data` after every derivation, not just exit code (see Code Examples) |
| `credentials.json` world-readable, exposing a reusable Connect session to any local user | Information Disclosure | Match existing `PKCE::storeTokens` convention: `chmod 0700` on the account directory (already done in `Settings.pm::_pkceStoreAccount` L501); the file itself is written by the Rust binary — verify it inherits restrictive permissions or add an explicit `chmod 0600` after derivation completes, since Perl-side derivation code controls the directory but not directly the Rust binary's `open()` mode bits |
| Two concurrent derivation attempts for the same account corrupt `credentials.json` mid-write | Tampering / DoS | In-flight guard keyed by `accountId` (Pitfall 3) prevents concurrent `--token-login` invocations; the Rust binary's own atomic write-then-rename (librespot-core `Cache::save_credentials`) provides defense-in-depth even if the guard is bypassed |

## Sources

### Primary (HIGH confidence)

- `Plugins/SpotOn/Bin/x86_64-linux/spoton --check` (local execution) — confirmed `token-login:true`, binary version v2.0.11
- `librespot-spoton/src/main.rs` (local repo, `run_token_login`, `run_get_token`, error propagation, L345-421) — read directly
- `librespot-spoton/src/unified.rs` (local repo, "Phase 14 (Credential Isolation)" L1248-1266, ZeroConf reconnect loop L1540-1650) — read directly
- `~/.cargo/git/checkouts/librespot-0af58e53e65aac12/db1ef7a/core/src/connection/mod.rs` (vendored librespot-core source, `login_error_message()` L22-34) — read directly, exact error strings verified
- `~/.cargo/git/checkouts/librespot-0af58e53e65aac12/db1ef7a/core/src/session.rs` (L206-244, `Session::connect` error handling) — read directly
- `.claude/skills/spike-findings-spoton/references/credential-bridge.md` — canonical spike synthesis (Spikes 004, 005), VALIDATED verdict
- `.claude/skills/spike-findings-spoton/sources/004-credential-derivation/README.md` and `derive_creds.pl` — original spike source, VALIDATED
- `.claude/skills/spike-findings-spoton/sources/005-connect-with-derived-creds/README.md` — original spike source, VALIDATED
- `Plugins/SpotOn/Unified/Daemon.pm`, `Plugins/SpotOn/Unified/DaemonManager.pm` (local repo) — existing async-poll, crash-loop, credential pre-check patterns, read directly
- `Plugins/SpotOn/API/PKCE.pm`, `Plugins/SpotOn/API/TokenManager.pm` (local repo) — token lifecycle, in-flight coalescing pattern, read directly
- `Plugins/SpotOn/Settings.pm` (local repo, `_pkceStoreAccount`/`_pkceFinishAuth` L423-520) — exact insertion point for Eager derivation, read directly
- `.planning/notes/keymaster-audit.md` — 4-bucket classification confirming `--token-login` and `run_token_login()` status ("Bucket 4: PKCE Path — EXISTS")
- Git history: commit `9874835` ("fix: token capture broken on Windows service (SPOTON_TOKEN_FILE)") — confirms cross-platform stdout-piping pitfall precedent

### Secondary (MEDIUM confidence)

- CHANGELOG.md (local repo) — release history context, cross-referenced against binary version

### Tertiary (LOW confidence)

- None — all findings for this phase were verifiable directly against local source (Perl codebase, Rust fork source, vendored librespot-core source) or the spike-findings skill's already-VALIDATED verdicts. No unverified WebSearch-only claims were needed.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies; existing binary capability verified via local `--check` execution
- Architecture: HIGH — traced through actual Perl and Rust source (both the LMS plugin and the librespot fork are present in this repo/environment), not inferred
- Pitfalls: HIGH — the stderr-capture gap (Pitfall 1) and the D-06 `scheduleInit` conditional gap (Pitfall 6) were discovered by reading the actual current code paths, not assumed

**Research date:** 2026-07-14
**Valid until:** 2026-08-13 (30 days — stable domain, but flag for recheck if `librespot-spoton`'s vendored `librespot-core` dependency is upgraded, since Pitfall 2's exact error strings are version-pinned per Assumption A2)

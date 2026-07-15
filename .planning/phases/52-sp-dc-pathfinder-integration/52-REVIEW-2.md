---
phase: 52-sp-dc-pathfinder-integration
reviewed: 2026-07-15T00:00:00Z
depth: deep
files_reviewed: 8
files_reviewed_list:
  - Plugins/SpotOn/API/WebPlayer.pm
  - Plugins/SpotOn/API/Client.pm
  - Plugins/SpotOn/Plugin.pm
  - Plugins/SpotOn/Settings.pm
  - Plugins/SpotOn/Status.pm
  - Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html
  - Plugins/SpotOn/strings.txt
  - t/17_webplayer_totp.t (+ t/08, t/09, t/13, t/14, t/18-21 via diff)
findings:
  critical: 0
  warning: 7
  info: 9
  total: 16
status: issues_found
---

# Phase 52: Code Review Report (Second Pass)

**Reviewed:** 2026-07-15
**Depth:** deep (cross-file: WebPlayer → Client → Plugin call chains traced)
**Scope:** 20 commits b38e3ce^..977fd10 on `v3.0-auth`
**Status:** issues_found

Severity levels per review request: CRITICAL (must fix) / HIGH (should fix) / MEDIUM (consider) / LOW (nit). Frontmatter mapping: critical=CRITICAL, warning=HIGH+MEDIUM, info=LOW.

## Summary

The security-sensitive invariants hold up under adversarial reading:

- **No token/credential leakage found.** sp_dc appears only in the Cookie header of `_requestToken` (WebPlayer.pm:427), scoped to `TOKEN_URL` exactly as T-52-03 demands. Bearer/client-token values are passed as headers only, never interpolated into log lines. All log call sites use `_mask()` (4-char prefix — the established TokenManager convention).
- **Rate-limit isolation is correct.** Both WP entry points check and set only `spoton_wp_rate_limit` (Client.pm:502/584/825/898); the Browse pipeline's `spoton_rate_limit` is untouched by WP 429s. t/08 WP-03 covers this.
- **ID validation is consistent** (`^[A-Za-z0-9]{1,40}$` on playlist IDs before any HTTP; extracted Pathfinder IDs re-validated after the `37i9` URI match).
- **TOTP implementation verified independently** — I recomputed the t/17 vector (`578737`) from the algorithm and it matches; `delete ... || []` precedence in the coalescing drain also verified safe.
- Defensive GraphQL parsing is thorough on the traversal side (ref checks at every level, fail-to-empty).

No CRITICAL findings. One HIGH (partial-token cache poisoning), six MEDIUM, nine LOW.

## High

### HI-01: Transient client-token failure poisons the WP token cache for up to ~55 minutes

**File:** `Plugins/SpotOn/API/WebPlayer.pm:366-377` (with `Plugins/SpotOn/API/Client.pm:616,927`)
**Issue:** In `_requestToken`'s success path, `_clientToken` failures resolve with `$clientToken = undef`, but the result `{ access_token => ..., client_token => undef }` is **still cached via `_cacheToken` with the full mint TTL** and `_setState(STATE_VALID)` is called. Every subsequent Pathfinder request for the next ~55 minutes then sends `'client-token' => ''` (empty header, Client.pm:616/927). If api-partner rejects requests lacking a client token with 400/403 (only 401 invalidates the cached WP token), Made For You silently shows "No results" for the whole cache period with `state() == valid`, and there is no self-heal path.

This also contradicts the module's own contract: the `_clientToken` docstring says *"a missing client-token degrades the caller to 'mint_failed'"* — the code does the opposite.

**Fix:** Either (a) treat a missing client-token as `mint_failed` and do NOT cache (matches the docstring), or (b) cache with a short TTL (e.g. 60s) when `client_token` is undef and omit the `client-token` header entirely instead of sending an empty value:

```perl
unless ($clientToken) {
    # Transient: do not poison the cache for the full token TTL
    $resolve->(undef, 'mint_failed');
    return;
}
```

## Medium

### ME-01: `_fetchAllPages` offset invariant broken by pre-filtered GraphQL items → duplicate tracks

**File:** `Plugins/SpotOn/API/Client.pm:753-761` (with `Plugins/SpotOn/Plugin.pm:1551-1552,2683-2690`)
**Issue:** `_transformPlaylistContents` **skips** non-track entries (episodes, local files, malformed URIs: `next unless $uri =~ /^spotify:track:/`) before returning `items`, while `total` remains the server-side count. `_fetchAllPages` computes the next page offset as `scalar(@accumulated)` — the count of *returned* items. In the REST path this invariant holds because null-track entries are kept and filtered later in Plugin.pm (`grep { defined $_->{track} }`). In the WP path, any skipped entry makes the next offset lower than the true server offset, so play-all re-fetches overlapping ranges and produces **duplicate tracks**; a page consisting entirely of skipped entries terminates pagination early (partial playlist, silently).

**Fix:** Preserve entry count parity with REST — emit placeholders for skipped entries instead of dropping them, so downstream `grep { defined $_->{track} }` does the filtering:

```perl
# in _transformPlaylistContents, instead of `next`:
push @items, { track => undef } and next unless $uri =~ /^spotify:track:([A-Za-z0-9]+)$/;
```

### ME-02: totpVerExpired retry unreachable if the token endpoint answers 200 with an error body

**File:** `Plugins/SpotOn/API/WebPlayer.pm:354-364,391-406`
**Issue:** The Pitfall-2 retry (force-refresh secret, retry once) only lives in the **error callback** (`$body =~ /totpVerExpired/i`). If `open.spotify.com/api/token` returns HTTP 200 with a JSON body carrying the error (a shape several community implementations report — missing/empty `accessToken` plus an error field), the success callback takes the `!$tokenData->{accessToken}` branch and resolves `mint_failed` **without ever refreshing the secret**. A rotated TOTP version then fails every mint until the 6h `SECRET_URL` cache expires, with no forceRefresh path exercised.
**Fix:** In the success-callback parse-failure branch, check the decoded body for a totpVer/totp error indicator (or simply: if `accessToken` is missing and `!$isRetry`, do one forceRefresh-secret retry before resolving `mint_failed`).

### ME-03: No dedup of playlist IDs across home sections → duplicate Made For You menu entries

**File:** `Plugins/SpotOn/API/Client.pm:659-688`
**Issue:** `_extractPathfinderIds` walks *all* sections of the home response and pushes every matching `37i9` playlist. The Pathfinder home feed routinely surfaces the same playlist in multiple sections ("Made for you", "Your heavy rotation", "Recently played"). Each occurrence becomes a separate OPML item in `_madeForYouFeed` — the user sees Daily Mix 1 two or three times.
**Fix:** Track seen IDs:

```perl
my %seen;
...
next if $seen{$id}++;
push @playlists, { id => $id, name => $name, images => $images };
```

### ME-04: `_madeForYouFeed` collapses 'expired' (and 'rate_limited'/'no_spdc') into generic "No results"

**File:** `Plugins/SpotOn/Plugin.pm:1288-1294`
**Issue:** Only `no_secrets` gets a specific message. But `expired` is a *common* on-click outcome: the `state()` cache lasts only 300s and defaults to 'valid' ("innocent until proven guilty"), so an expired sp_dc regularly passes the `_homeFeed` gate and fails at fetch time with `{ error => 'expired' }` — the user then sees "No results" instead of the existing, translated `PLUGIN_SPOTON_SP_DC_EXPIRED_HINT`. That hint string plus `_madeForYouExpiredFeed` already exist; this path just doesn't use them. Same for `rate_limited` ("No results" is misleading for a transient 429).
**Fix:**

```perl
my $name = $reason eq 'no_secrets' ? cstring($client, 'PLUGIN_SPOTON_MFY_SECRETS_DOWN')
         : $reason eq 'expired'    ? cstring($client, 'PLUGIN_SPOTON_SP_DC_EXPIRED_HINT')
         :                           cstring($client, 'PLUGIN_SPOTON_NO_RESULTS');
```

### ME-05: WP request path bypasses the central concurrency cap and telemetry

**File:** `Plugins/SpotOn/API/Client.pm:496-626,818-937`
**Issue:** `pathfinderHome` and `getWebPlayerPlaylistItems` dispatch SimpleAsyncHTTP directly, outside `_request`: no `MAX_CONCURRENT_REQUESTS` cap, no `$inflightCount`, and `$apiRequestCount` is never incremented (while `$api429Count` **is** — the Status page ratio is now inconsistent). CLAUDE.md P-01/NFL-03 mandates one central throttle through which ALL requests flow. Separate *rate-limit pools* are correct and intended (T-52-04), but a separate pool doesn't require bypassing the concurrency cap: N players opening Made For You simultaneously fire N parallel Pathfinder POSTs plus play-all pagination chains with no ceiling. Also, `statusSnapshot()`'s `rateLimited` flag only reflects `spoton_rate_limit`, so a WP 429 is invisible there despite incrementing `api429Count`.
**Fix:** Apply the same inflight counter/defer-timer pattern (or a WP-scoped counter) to the two WP methods; increment `$apiRequestCount` per WP request; expose `wpRateLimited => $cache->get(WP_RATE_LIMIT_KEY) ? 1 : 0` in `statusSnapshot`.

### ME-06: `%_mintInflight` has no recovery path — a single escaped die permanently wedges minting for an account

**File:** `Plugins/SpotOn/API/WebPlayer.pm:57,296-337`
**Issue:** The drain (`$resolve`) eval-guards the *queued callbacks*, but the mint chain itself (`getSecret` cb → `_serverTime` cb → `_requestToken` → `_clientToken`) runs with no eval between `$_mintInflight{$accountId} = [$cb]` and `$resolve`. Client.pm's `_request` treats exactly this hazard as a first-class failure mode (the H1 comment and eval guards); WebPlayer has no equivalent. If any step dies before `$resolve` fires (e.g. a die escaping inside a SimpleAsyncHTTP callback), the inflight entry is never deleted: every future `getToken()` for that account coalesces into the dead queue **forever** — Made For You silently dead until server restart. There is also no `reset()` hook clearing `%_mintInflight` on plugin init (Client.pm resets its counters for exactly this reason, RESEARCH Pitfall 2).
**Fix:** Wrap the chain entry points in `eval { ... } or $resolve->(undef, 'mint_failed')`, and add a `reset()` classmethod (clearing `%_mintInflight`) called from `Plugin.pm::initPlugin` alongside `Client->reset()`.

## Low

### LO-01: Dead code — `_fetchAllPersonalMixes` / `getPersonalMixes` orphaned by the Pathfinder rewrite

**File:** `Plugins/SpotOn/Plugin.pm:1246-1274`, `Plugins/SpotOn/API/Client.pm:359-377`
**Issue:** `_madeForYouFeed` no longer calls them (t/14:624 even asserts this), leaving both functions with zero callers. `getPersonalMixes` also targets `browse/categories/{id}/playlists`, removed in Feb-2026 dev mode per CLAUDE.md.
**Fix:** Delete both, plus the now-unused `PERSONAL_MIX_CATEGORY` constant.

### LO-02: Unused constant `WP_GQL_HASH_CACHE_KEY`

**File:** `Plugins/SpotOn/API/Client.pm:38`
**Issue:** Defined, never referenced (leftover of the removed hash-cache design; the hash now lives in the `pathfinderHash` pref).
**Fix:** Remove the constant.

### LO-03: `storeSpDc` removes a cache key that is never written

**File:** `Plugins/SpotOn/API/WebPlayer.pm:226`
**Issue:** `spoton_wp_client_token_${accountId}` is removed on store, but nothing ever sets that key (the client token is embedded in the `spoton_wp_token_*` hash). Misleading — implies a separate client-token cache exists.
**Fix:** Drop the line or add a comment that it is a defensive legacy-key sweep.

### LO-04: `_cacheToken` caches an already-expired token for 30s on negative TTL

**File:** `Plugins/SpotOn/API/WebPlayer.pm:513-519`
**Issue:** If `accessTokenExpirationTimestampMs` is in the past (clock skew / stale response), `$secondsLeft` is negative and the `: 30` fallback still caches the dead token for 30s; `getToken` will serve it.
**Fix:** `return` without caching when `$secondsLeft <= TOKEN_EXPIRY_BUFFER`.

### LO-05: `_mask` leaks the full value for inputs ≤4 characters

**File:** `Plugins/SpotOn/API/WebPlayer.pm:85-89` (same in `Plugin.pm::_mfyMaskAccount:1190-1194`)
**Issue:** `substr($value, 0, 4) . '****'` returns the *entire* value + asterisks when `length ≤ 4`. A degenerate short sp_dc (garbage paste surviving sanitization) would be logged in full by `storeSpDc`.
**Fix:** `return '****' if length($value) <= 4;`

### LO-06: Hardcoded `timeZone => 'Europe/Berlin'` default in the home query

**File:** `Plugins/SpotOn/API/Client.pm:528`
**Issue:** No caller passes `timeZone`, so every install claims Berlin. Daylist content is time/timezone-sensitive; users in other zones get skewed daylists.
**Fix:** Derive from the server (`POSIX::strftime('%z', ...)` mapping, or LMS server timezone) and keep Berlin only as last resort.

### LO-07: Placeholder home hash is POSTed on every Made For You open when the pref is unset

**File:** `Plugins/SpotOn/API/Client.pm:522,53`
**Issue:** With `pathfinderHash` unset, each menu open runs the full mint chain plus a doomed Pathfinder POST with the literal `REPLACE_WITH_LIVE_CAPTURED_...` string as `sha256Hash`, always yielding the degraded-empty result. Status.pm already exposes `hashConfigured` — the client could short-circuit.
**Fix:** When the effective hash equals `PATHFINDER_HOME_HASH_DEFAULT`, return `$cb->([], undef)` (with the Pitfall-4 log line) before minting/POSTing.

### LO-08: totpVerExpired retry reuses the original `$epoch`

**File:** `Plugins/SpotOn/API/WebPlayer.pm:403`
**Issue:** The retry after force-refreshing the secret passes the epoch fetched before the first attempt; the secret refetch adds seconds, so near a 30s window boundary the retry OTP can fall into a stale window.
**Fix:** Re-run `_serverTime` (or add elapsed wall time) before the retry.

### LO-09: MFY priority sorting depends on English playlist names without the previous EN-locale safeguard

**File:** `Plugins/SpotOn/Plugin.pm:1229-1243,1297-1299`
**Issue:** The old implementation fetched an explicit `en` locale pass for locale-independent sorting; the Pathfinder rewrite sorts on whatever names the home response returns. Most of these brands are untranslated, but any localized name silently drops to the lowest priority tier. Also note the unauthenticated `/plugins/SpotOn/status/data` endpoint now includes `spDcMasked` (4-char prefix) — consistent with existing status-page exposure, but worth a conscious decision.
**Fix:** Accept and document, or match on additional localized variants where Spotify does translate.

## Verified Non-Issues (adversarial checks that passed)

- sp_dc never sent to `api-partner.spotify.com` or `clienttoken.spotify.com`; Cookie header confined to `TOKEN_URL`.
- Settings masked-preview resubmit logic (Settings.pm:139-161): comparison happens against the whitespace-trimmed raw value *before* charset sanitization strips `*` — the ordering bug called out in the code comment is correctly avoided; empty submission clears; no-account submissions are no-ops.
- `pathfinderHash` input: hex-only + 128-char cap; sp_dc input: charset-restricted + 512 cap — no injection surface into prefs.
- `delete $_mintInflight{$accountId} || []` parses as `(delete ...) || []` (verified with perl) — no precedence bug.
- t/17 TOTP vector `578737` independently recomputed and confirmed.
- `_getAccountId` returns `''` (never undef) — no uninitialized-value warnings in WP cache keys from the OPML path.
- `_parseAndValidate` fail-closed whole-payload rejection is correct; `MAX_CIPHER_LEN` bounds untrusted array length; no eval of fetched payload.
- Retry-After parsing clamped to [1,300] in both WP handlers, matching the Browse pipeline (T-02-08).
- Play-all cache key isolation `mfyplaylist:` vs `playlist:` prevents WP/REST result cross-contamination for the same playlist ID.

---

_Reviewed: 2026-07-15_
_Reviewer: Claude (gsd-code-reviewer, adversarial second pass)_
_Depth: deep_

# Keymaster Token Usage Audit

**Date:** 2026-07-13
**Purpose:** Baseline for v3.0 Auth Overhaul — classify every Keymaster reference into 4 buckets before Phase 53 removes them.

## Bucket Definitions

1. **Real Keymaster Service** — Code that calls `hm://keymaster/token/authenticated` (via librespot's `token_provider().get_token()`) to obtain Web API tokens. This is the core functionality being replaced by PKCE.
2. **Client-ID as Identity Hint** — Code that uses a Spotify Client-ID (`SPOTON_DEFAULT_CLIENT_ID`, `KEYMASTER_CLIENT_ID`, user's `clientId` pref) as a platform identity parameter. These are not Keymaster *calls* — they're identity strings passed to ZeroConf Discovery and `--get-token`. Some will remain post-PKCE (Discovery needs a client_id for mDNS), some become PKCE's client_id.
3. **Login5 Path** — Code related to librespot's internal login5 authentication (session bootstrap, spclient Bearer tokens). Not touched by v3.0 — librespot handles this internally.
4. **PKCE Path** — Code that already exists for PKCE OAuth (currently: only the diagnostic test script). This bucket will grow during v3.0 implementation.

## Findings

### Bucket 1: Real Keymaster Service (REMOVE in Phase 53)

| File | Lines | What It Does |
|------|-------|-------------|
| `librespot-spoton/src/main.rs` | 479-532 | `run_get_token()` — spawns librespot session, calls `session.token_provider().get_token()` or `.get_token_with_client_id()`. **This is THE Keymaster call.** Returns JSON with `accessToken`, `expiresIn`, `tokenType`. |
| `librespot-spoton/src/main.rs` | 131, 329-334 | `--get-token` CLI flag parsing and validation. Entry point for Keymaster token retrieval. |
| `Plugins/SpotOn/API/TokenManager.pm` | 398-618 | `_fetchKeymasterToken()` — spawns `spoton --get-token --cache <dir> --client-id <id>`, parses JSON output, caches token. Entire method is Keymaster-specific. |
| `Plugins/SpotOn/API/TokenManager.pm` | 53-75 | `getToken()` — check cache, fallback to `_fetchKeymasterToken()`. Cache logic stays, fetch method changes. |
| `Plugins/SpotOn/API/TokenManager.pm` | 167-177 | `refreshExpiring()` — proactively refreshes tokens via `_fetchKeymasterToken()`. Needs to call PKCE refresh instead. |
| `Plugins/SpotOn/API/TokenManager.pm` | 649-659 | `_fetchDisplayName()` — uses `_fetchKeymasterToken()` to get token for `/me` call. |
| `Plugins/SpotOn/API/TokenManager.pm` | 383-395 | `_fetchDisplayNameForNewAccount()` — same pattern, `_fetchKeymasterToken()` for display name. |
| `Plugins/SpotOn/API/TokenManager.pm` | 556-612 | Keymaster error diagnostics — parses MercuryResponse status codes, decodes byte-array payloads, logs `keymaster_status: HTTP 403`. All Keymaster-specific error handling. |
| `Plugins/SpotOn/API/Client.pm` | 681-683 | Bundled fallback comment: "if own-token retrieval fails (e.g. Keymaster 403 for custom Client ID)". Logic stays, comment/semantics change. |
| `Plugins/SpotOn/API/Client.pm` | 815 | Comment: "bundled tokens share the same Keymaster user session". Becomes incorrect post-PKCE. |
| `Plugins/SpotOn/strings.txt` | 704-714 | `PLUGIN_SPOTON_CLIENT_ID_DESC` — 11 languages mentioning "Keymaster server rejects newer Client IDs". Needs rewriting for PKCE context. |
| `Plugins/SpotOn/strings.txt` | 1341-1351 | Setup Guide text — 11 languages mentioning "Spotify Keymaster rejects newer Client IDs". Needs rewriting. |

### Bucket 2: Client-ID as Identity Hint (KEEP, repurpose for PKCE)

| File | Lines | What It Does |
|------|-------|-------------|
| `Plugins/SpotOn/API/Client.pm` | 31 | `SPOTON_DEFAULT_CLIENT_ID` constant (`d420a117...`). Bundled Client-ID — currently used for Keymaster, will become PKCE client_id (if Extended Quota approved) or be replaced. |
| `Plugins/SpotOn/API/Client.pm` | 613-622 | `_resolveStartFlavor()` — routes `me/*` to own vs bundled Client-ID. Logic concept stays (PKCE may still have own vs default), implementation changes. |
| `Plugins/SpotOn/API/Client.pm` | 685-710 | Fallback logic using `$prefs->get('clientId')` and `SPOTON_DEFAULT_CLIENT_ID`. Client-ID selection stays, token source changes. |
| `Plugins/SpotOn/API/TokenManager.pm` | 26-31 | Imports `SPOTON_DEFAULT_CLIENT_ID` from Client.pm. |
| `Plugins/SpotOn/API/TokenManager.pm` | 448-455 | Flavor dispatch: bundled → `SPOTON_DEFAULT_CLIENT_ID`, own → `$prefs->get('clientId')`. Selection logic stays. |
| `Plugins/SpotOn/Settings.pm` | 73, 105-113 | `clientId` pref save with 32-char hex validation. Stays — PKCE also needs a Client-ID. |
| `Plugins/SpotOn/Settings.pm` | 212-213, 375-376, 536-541 | Display custom Client-ID in settings/diagnostics, degraded mode detection. Concept stays with PKCE. |
| `Plugins/SpotOn/HTML/EN/.../basic.html` | 124-135 | Client-ID input field in Settings HTML. Stays — PKCE needs Client-ID input too. |
| `librespot-spoton/src/main.rs` | 99, 251-253 | `--client-id` CLI arg parsing. Stays — passed to `--get-token` and Discovery. |
| `librespot-spoton/src/main.rs` | 569-576 | `KEYMASTER_CLIENT_ID` constant for ZeroConf Discovery. Name misleading — it's just the librespot default client_id for mDNS. Rename, keep. |
| `librespot-spoton/src/unified.rs` | 1553-1573 | Same `KEYMASTER_CLIENT_ID` for ZeroConf Discovery in unified daemon. Rename, keep. |
| `Plugins/SpotOn/Unified/DaemonManager.pm` | 162-700 | `$clientId` variable throughout — this is actually the LMS *player* client ID (MAC address), NOT a Spotify Client-ID. **Not Keymaster-related at all.** No changes needed. |
| `Plugins/SpotOn/ProtocolHandler.pm` | 72 | `$clientId` in `%_browse404Retries` — same as above, LMS player ID. Not Keymaster-related. |
| `Plugins/SpotOn/strings.txt` | 690, 716-727 | `PLUGIN_SPOTON_CLIENT_ID_SETTINGS`, `PLUGIN_SPOTON_CLIENT_ID_PLACEHOLDER` — generic Client-ID labels. Stay. |

### Bucket 3: Login5 Path (NO CHANGES — librespot internal)

| File | Lines | What It Does |
|------|-------|-------------|
| `librespot-spoton/src/main.rs` | 425-461 | `run_login()` and `run_token_login()` — authenticate via login5 (password or access_token → stored credentials). Login5 is librespot's internal session auth — stays. `run_token_login()` is actually the credential derivation path (PKCE token → stored creds), already implemented. |
| `librespot-spoton/src/main.rs` | 518-522 | Comment "Get token via Keymaster/Mercury protocol" — misleading. The `session.token_provider()` calls go through Mercury to Keymaster. This IS Bucket 1, but the session setup (login5) that precedes it is Bucket 3. |

### Bucket 4: PKCE Path (EXISTS — expand in v3.0)

| File | Lines | What It Does |
|------|-------|-------------|
| `librespot-spoton/src/main.rs` | 448-461 | `run_token_login()` — takes an access_token, creates `Credentials::with_access_token()`, authenticates session, returns stored credentials. **This is the credential derivation path that PKCE will use.** Already functional. |
| `tools/spoton-pkce-audiokey-test.sh` | entire | PKCE diagnostic script — full PKCE flow (code_verifier, code_challenge, auth URL, token exchange, credential derivation, Connect test). Reference implementation for Phase 49. |

## Summary

| Bucket | Count | v3.0 Action |
|--------|-------|-------------|
| 1: Real Keymaster Service | 12 locations | **Remove** — replace with PKCE token refresh |
| 2: Client-ID as Identity | 15 locations | **Keep** — rename `KEYMASTER_CLIENT_ID` to `DISCOVERY_CLIENT_ID`, repurpose for PKCE |
| 3: Login5 (librespot internal) | 3 locations | **No change** — librespot handles internally |
| 4: PKCE Path | 2 locations | **Expand** — this is what v3.0 builds |

## Key Observations

1. **The blast radius is concentrated:** `TokenManager.pm` (especially `_fetchKeymasterToken()`) and `main.rs:run_get_token()` contain ~80% of the Keymaster-specific code. Phase 50 (TokenManager Rewrite) is correctly scoped.

2. **`--get-token` CLI flag becomes obsolete:** Post-PKCE, tokens come from the Perl-side refresh flow, not from spawning a binary. The `--get-token` code path in `main.rs` can be removed entirely.

3. **`--token-login` already exists:** The credential derivation path (`Credentials::with_access_token()`) is already implemented and tested. Phase 51 (Credential Derivation) builds on working code.

4. **`KEYMASTER_CLIENT_ID` naming is misleading:** The constant in `main.rs:569` and `unified.rs:1553` is used for ZeroConf Discovery, not for Keymaster token retrieval. Rename to `DISCOVERY_CLIENT_ID` for clarity.

5. **i18n strings need updating:** 22 translated strings across 11 languages mention "Keymaster" — needs rewriting in Phase 53 (or earlier if UX changes in Phase 49).

6. **DaemonManager `$clientId` is a false positive:** It's the LMS player MAC address, not a Spotify Client-ID. No changes needed.

7. **UAT gate confirmed:** `hm://keymaster/token/authenticated` only appears in the `token_provider().get_token()` call chain. Removing `run_get_token()` and `_fetchKeymasterToken()` eliminates all real Keymaster service calls. The UAT gate ("no hm://keymaster/token/authenticated in normal logs") will pass.

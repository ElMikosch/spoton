# Phase 52: sp_dc + Pathfinder Integration - Context

**Gathered:** 2026-07-14
**Status:** Ready for planning

<domain>
## Phase Boundary

This phase adds "Made for You" content (Daily Mix, Discover Weekly, Release Radar, Daylist, genre mixes) to SpotOn. These are Spotify-owned algorithmic playlists (37i9... IDs) that are inaccessible via the standard Web API in Development Mode since Feb 2026. The workaround uses the sp_dc browser session cookie to obtain a Web-Player token, which accesses the Pathfinder GraphQL API for playlist discovery and the standard playlist endpoint for track retrieval.

**In scope:** sp_dc cookie input/storage, Web-Player token lifecycle (TOTP, token request, refresh), Pathfinder Home Feed query, algorithmic playlist extraction, playlist track access, OPML menu integration, graceful degradation.

**Out of scope:** Automated sp_dc extraction (HttpOnly cookie, manual browser DevTools extraction required), self-hosted TOTP secret scraping/publishing (deferred — use community source first), Keymaster removal (Phase 53).

</domain>

<decisions>
## Implementation Decisions

### TOTP Secret Source
- **D-01:** Use xyloflake/spot-secrets-go JSON from GitHub as TOTP secret source. Code architecture MUST be pluggable — the secret source is behind an interface/config so it can be swapped to a self-hosted source later without code changes.
- **D-02:** If xyloflake is unreachable, degrade gracefully (no Made for You, log warning). No local bundle scrape in this phase.

### Degradation & UX
- **D-03:** No sp_dc configured → "Made for You" menu item hidden entirely + info log line.
- **D-04:** sp_dc expired (token request fails) → Warning in three places: OPML menu (Made for You shows "sp_dc expired" hint), Settings page (status indicator), and Status page. Log warning.
- **D-05:** TOTP secrets unavailable (xyloflake down) → Same degradation as D-03 (menu hidden), but with distinct log message so the cause is diagnosable.

### Token Architecture
- **D-06:** New module `Plugins::SpotOn::API::WebPlayer` — owns the complete Web-Player token lifecycle: sp_dc storage access, TOTP generation, token request/refresh/caching, client-token acquisition. Fully separate from PKCE (TokenManager) and Keymaster.
- **D-07:** TokenManager does NOT learn about Web-Player tokens. API/Client.pm calls WebPlayer->getToken() directly when it needs a Web-Player-scoped request (Pathfinder, 37i9... playlists).

### sp_dc Input & Security
- **D-08:** Dedicated "Made for You" section in Settings page — sp_dc text field with collapsible how-to instructions (browser DevTools screenshot/steps), status indicator (valid/expired/empty).
- **D-09:** sp_dc stored in LMS prefs under the account key (consistent with PKCE tokens). Masked in all logs: `sp_dc=AQDx****`.
- **D-10:** sp_dc is ~1 year valid, no programmatic refresh. User re-extracts from browser on expiry.

### Claude's Discretion
- sp_dc storage location within prefs structure (D-09 sets the pattern, exact key name is implementation detail)
- GraphQL hash caching strategy (in-memory vs. prefs vs. cache DB)
- Pathfinder response parsing and playlist filtering logic
- Web-Player token caching TTL and refresh strategy
- Client-token acquisition and caching

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike Findings
- `.claude/skills/spike-findings-spoton/references/pathfinder-made-for-you.md` — Complete implementation blueprint: TOTP decode chain, token request format, Pathfinder query structure, playlist extraction, access token requirements

### API Context
- `CLAUDE.md` §Spotify Web API v1 — Endpoint status table, Feb 2026 changes, removed endpoints (categories, featured playlists, batch endpoints)
- `CLAUDE.md` §OAuth Scopes — Required scopes for playlist access
- `CLAUDE.md` §Rate Limits — Rolling 30s window, web-player client_id has separate rate pool

### Existing Code (integration points)
- `Plugins/SpotOn/API/Client.pm` — Central HTTP client, all requests flow through here
- `Plugins/SpotOn/API/TokenManager.pm` — PKCE token management (do NOT integrate Web-Player here per D-07)
- `Plugins/SpotOn/Settings.pm` — Settings page (add new "Made for You" section per D-08)
- `Plugins/SpotOn/Plugin.pm` — OPML menu registration (add Made for You menu item)
- `Plugins/SpotOn/strings.txt` — i18n strings for new UI elements

### External Dependencies
- `xyloflake/spot-secrets-go` (GitHub) — TOTP secret source (D-01)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `API/Client.pm` HTTP pipeline: SimpleAsyncHTTP with central throttling — Web-Player requests can reuse this with a different token source
- `API/PKCE.pm` token storage pattern: `storeTokens`/`loadTokens` with account-scoped dirs — mirror for sp_dc prefs storage
- `Settings.pm` section pattern: existing account/player sections show how to add a new settings section with validation
- `strings.txt` i18n pattern: 11-language template for new strings

### Established Patterns
- Token caching: TokenManager caches in Slim::Utils::Cache with TTL — WebPlayer should follow same pattern
- Prefs masking: `substr($id,0,4).'****'` convention for all log lines (T-29-07)
- Async callback chains: cb($ok, $reason) pattern established in Credentials.pm, TokenManager
- HTTP error handling: Client.pm's onError pattern with structured error objects

### Integration Points
- Plugin.pm `initPlugin()`: register Made for You OPML menu
- Settings.pm: new "Made for You" settings section
- Client.pm: route Pathfinder/37i9... requests through WebPlayer token
- strings.txt: new i18n keys for Made for You section, sp_dc expiry warning

</code_context>

<specifics>
## Specific Ideas

- Web-Player token endpoint: `GET https://open.spotify.com/api/token?reason=transport&productType=web-player&totp=...&totpServer=...&totpVer=...` with Cookie header
- Client-token from `POST https://clienttoken.spotify.com/v1/clienttoken`
- Pathfinder query: `POST https://api-partner.spotify.com/pathfinder/v2/query` with GraphQL persisted query
- Algorithmic playlist IDs (37i9...) are per-user unique but stable — cache them in prefs after first discovery
- Web-Player token needed for BOTH Pathfinder discovery AND `/playlists/{id}/items` on 37i9... playlists

</specifics>

<deferred>
## Deferred Ideas

- **Self-hosted TOTP secret scraping:** Build own scrape+publish pipeline (CI job, JSON in repo). Currently using community source (D-01). Revisit when/if xyloflake becomes unreliable.
- **Automated sp_dc extraction:** HttpOnly cookie prevents programmatic access. Would need browser automation or Spotify login flow integration. Low priority given ~1 year validity.
- **Additional Pathfinder content:** Beyond Made for You — Recently Played radio, artist radio, mood playlists. Explore after core integration works.

</deferred>

---

*Phase: 52-sp_dc + Pathfinder Integration*
*Context gathered: 2026-07-14*

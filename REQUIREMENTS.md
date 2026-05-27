# Requirements: Neues Spotify-Plugin für Lyrion Music Server

> Projektname: **SpotOn**
> Status: DRAFT — Grundlage aus Spotty-NG v1+v2 Erfahrungen, iterativ zu ergänzen
> Erstellt: 2026-05-19

## 1. Vision

Ein von Grund auf neu gebautes Spotify-Plugin für Lyrion Music Server (LMS), das auf den Erfahrungen aus dem Spotty-NG-Projekt aufbaut. Dort wo Herger's Plugin historisch gewachsene Architektur-Schulden hat (parallele Pagination, OAuth-Komplexität, Connect als Nachgedanke), radikal neu denken. Dort wo LMS-Konventionen und librespot-Integration bewährte Muster haben, bewusst anknüpfen.

## 2. Harte Constraints (nicht verhandelbar)

| Constraint | Grund |
|---|---|
| **Perl** | LMS-Plugins sind Perl-Module unter `Slim::Plugin::*`. Kein Weg dran vorbei. |
| **LMS Plugin API** | `Slim::Plugin::OPMLBased`, `Slim::Networking::SimpleAsyncHTTP`, `Slim::Utils::Cache`, `Slim::Utils::Prefs` — das ist das Framework. |
| **librespot-basiert** | Die Spotify-Playback-API ist nicht öffentlich. `librespot` ist die einzige Open-Source-Implementierung für Streaming + Connect. |
| **Spotify Web API v1** | Für Browse, Search, Library, Player-State. OAuth2 erforderlich. |
| **Perl ≥ 5.10** | LMS-Floor (`require 5.010` in squeezeboxserver). |
| **Keine externen CPAN-Deps** | Was nicht in LMS gebundelt ist, blockiert Adoption. Alles mit Bordmitteln. |
| **Spotify Premium** | Streaming erfordert Premium-Account. |

## 3. Funktionale Anforderungen

### 3.1 Navigation & Browse Experience

> **Design-Prinzip:** Die Menüstruktur soll sich an der aktuellen Spotify-App orientieren, nicht an den API-Endpoints. Spotify-User erwarten eine bestimmte Informationsarchitektur — das Plugin soll diese innerhalb der LMS-OPML-Constraints so nah wie möglich abbilden.

#### Spotify-App Navigation (Stand 2025/2026)

Die Spotify-App hat drei Hauptbereiche:

**Home** — Personalisierter Feed
- Zuletzt gehört (Recently Played)
- "Made for You" Mixes (Daily Mix 1–6, basierend auf Hörverhalten)
- Release Radar (wöchentlich, neue Releases von gefolgten Artists)
- Discover Weekly (wöchentlich, algorithmische Empfehlungen)
- "Weil du X gehört hast..." — kontextuelle Empfehlungen
- Beliebte Playlists in deiner Region
- Neue Episoden von gefolgten Podcasts

**Suche** — Search + Browse
- Freitextsuche (Tracks, Albums, Artists, Playlists, Podcasts)
- Browse-Kategorien: Genres & Moods, Charts, Neuheiten, Podcasts
- "Browse All" Kategorie-Gitter

**Deine Bibliothek** — Persönliche Sammlung
- Playlists (eigene + gefolgte)
- Alben (gespeicherte)
- Künstler (gefolgte)
- Podcasts & Hörbücher
- Liked Songs (die große Sammlung)
- Sortierung: zuletzt hinzugefügt, alphabetisch, kürzlich gehört
- Filter: Playlists / Alben / Künstler / Podcasts

#### LMS-Constraint: OPML-Menübäume

LMS zeigt Plugins als hierarchische Menübäume (OPML). Kein Grid-Layout, keine Tabs, kein horizontales Scrolling. Wir müssen die Spotify-Logik in eine Baumstruktur übersetzen.

#### Requirements

| ID | Requirement | Priorität | Designquelle |
|---|---|---|---|
| NAV-01 | **Top-Level-Struktur** soll die drei Spotify-Hauptbereiche abbilden: Home, Suche, Bibliothek — als Top-Level-Menüpunkte | MUST | Spotify-App IA |
| NAV-02 | **Home-Feed**: Personalisierte Inhalte — Recently Played, Made For You Mixes, Release Radar, Discover Weekly. Reihenfolge orientiert an Spotify-App, nicht an API-Endpoint-Alphabetik. | MUST | Spotify Home |
| NAV-03 | **Bibliothek mit Filtern**: Liked Songs, Saved Albums, Saved Artists, Saved Playlists jeweils als Unterpunkt. Innerhalb sortierbar (zuletzt hinzugefügt als Default). | MUST | Spotify "Your Library" |
| NAV-04 | **Suche** — Freitextsuche mit Ergebnis-Kategorien (Tracks, Albums, Artists, Playlists) | MUST | Spotify Search |
| NAV-05 | **Browse-Kategorien** unter Suche: Genres & Moods, Charts, Neuheiten — als Unterpunkte der Suche, wie in der Spotify-App | SHOULD | Spotify Browse |
| NAV-06 | **Artist-Detailseite** — Top Tracks, Discography (Albums, Singles, Compilations), "Fans mögen auch" | MUST | Spotify Artist Page |
| NAV-07 | **Album-Detailseite** — Trackliste mit Tracknummer, Dauer, Featuring-Artists | MUST | Spotify Album Page |
| NAV-08 | **Playlist-Detailseite** — Tracks paginiert, Playlist-Beschreibung, Creator | MUST | Spotify Playlist Page |
| NAV-09 | **"Mehr wie das"** — Von Artist/Album/Playlist aus kontextuelle Empfehlungen erreichbar (sofern API es hergibt) | SHOULD | Spotify Kontextmenü |
| NAV-10 | **Online Library / Importer** — Spotify-Bibliothek in LMS-Datenbank importieren für lokale Suche via LMS-Suchfeld | SHOULD | Herger's Importer.pm |
| NAV-11 | **Menüstruktur-Research**: Vor der Implementierung die aktuelle Spotify-App systematisch durchgehen und die finale OPML-Baumstruktur als Mockup dokumentieren. Was mappt 1:1, was muss adaptiert werden, was geht in OPML nicht? | MUST | Design-Phase |

#### Offene Design-Frage: Herger's "Start" vs. Spotify "Home"

Herger nannte den personalisierten Bereich "Start" — ein Sammelbecken aus Featured Playlists, Categories, New Releases. Die Spotify-App hat "Home" mit einem viel stärker personalisierten, algorithmusgetriebenen Feed.

**Problem:** Viele der Home-Feed-Elemente in der Spotify-App basieren auf internen Recommendation-Engines die **nicht über die öffentliche Web API** zugänglich sind. Die API bietet:
- ✅ `me/top/tracks`, `me/top/artists` (personalisiert)
- ✅ `me/player/recently-played` (kürzlich gehört)
- ✅ `browse/featured-playlists` (redaktionell, nicht personalisiert)
- ✅ `browse/new-releases`
- ✅ `browse/categories`
- ❌ "Made for You" Mixes (Daily Mix 1–6) — **nicht direkt** via API
- ❌ "Weil du X gehört hast..." — nicht via API
- ⚠️ `recommendations` — seit 2024-11-27 deprecated für neue Apps

**Entscheidung nötig:** Wie nah können wir an die Spotify-Home-Experience kommen? Die Daily Mixes sind technisch Playlists auf dem User-Account — man könnte sie über `me/playlists` finden und filtern. Zu untersuchen in der Design-Phase.

### 3.2 Audio Streaming

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| STR-01 | **Single-Track-Modus**: librespot-Binary dekodiert einen Spotify-Track und schreibt PCM nach stdout | MUST | `--single-track` in Herger's Fork |
| STR-02 | **Transcoding-Pipeline** via `custom-convert.conf`: `spt → pcm`, `spt → flc`, `spt → mp3` | MUST | LMS-Konvention |
| STR-03 | **OGG-Kompatibilität**: Spotify liefert intern Vorbis/OGG. Nicht alle LMS-Player können OGG direkt. Konvertierung zu PCM/FLAC/MP3 muss zuverlässig funktionieren. | MUST | User-Hinweis + Herger's convert.conf |
| STR-04 | **Bitrate-Auswahl**: 96 / 160 / 320 kbps, per Plugin-Einstellung konfigurierbar | MUST | Herger's `$prefs->get('bitrate')` |
| STR-05 | **Volume Normalization** (Replay Gain): Optional, per Player konfigurierbar, mapped auf `--enable-volume-normalisation` | SHOULD | Herger's `canReplayGain` |
| STR-06 | **Seeking**: Seek-Position an Binary übergeben (`--start-position`) | MUST | `custom-convert.conf` RT-Substitution |
| STR-07 | **Audio Cache Management**: Konfigurierbar (an/aus, Größenlimit), Purge nach X Tracks | SHOULD | Herger's `purgeAudioCacheAfterXTracks` |
| STR-08 | **Gapless Playback**: Nächster Track muss nahtlos starten | SHOULD | UX-Erwartung |

### 3.3 Spotify Connect (Säule 3)

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| CON-01 | **Connect-Daemon pro Player**: Ein librespot-Prozess pro LMS-Player als Spotify Connect Receiver | MUST | Spotty-NG v2 |
| CON-02 | **Daemon Lifecycle**: Start bei Plugin-Init (wenn aktiviert), Stop bei Shutdown, Restart bei Crash | MUST | DaemonManager.pm |
| CON-03 | **Event-Dispatching**: Binary sendet Events (start/stop/change/volume/pause) via JSON-RPC an LMS; Plugin reagiert darauf | MUST | Connect.pm `_connectEvent` |
| CON-04 | **Transfer-Wiedergabe**: Spotify-App transferiert zu LMS → Audio startet innerhalb 3s | MUST | Spotty-NG Phase 8 |
| CON-05 | **Remote Control**: Play/Pause/Skip/Volume aus der Spotify-App steuern LMS-Player | MUST | Phase 8 |
| CON-06 | **Sync-Group-Handling**: Bei gesyncten Playern nur EIN Daemon auf dem Master. Name = concat der Player-Namen (`chilly & coffee`). | MUST | Spotty-NG Phase 9, heute bestätigt |
| CON-07 | **mDNS Discovery**: Connect-Receiver wird per mDNS im lokalen Netz angekündigt. Optional deaktivierbar. | MUST | `--disable-discovery` Flag |
| CON-08 | **Mutual Exclusion Streaming/Connect**: Gleichzeitiges Streaming via Browse und aktive Connect-Session dürfen sich nicht gegenseitig invalidieren (keine `credentials.json`-Korruption) | MUST | REG-02 aus Phase 8 |
| CON-09 | **`killHangingProcesses`-Guard**: LMS-internes Zombie-Killing darf laufende Connect-Daemons nicht killen | MUST | REG-01 aus Phase 8 |
| CON-10 | **Per-Player Enable/Disable**: Connect pro Player ein/ausschaltbar in den Settings | MUST | Phase 10 |
| CON-11 | **Volume-Suppression bei Connect-Start**: Initiale Volume-Events vom Binary nicht blind auf LMS-Player anwenden (verhindert Lautstärke-Sprünge) | SHOULD | CON-07 aus Phase 8 |
| CON-12 | **Stream-Mode Audio-Transport**: Audio vom Binary als kontinuierlicher Stream zu LMS (HTTP bevorzugt, FIFO als Fallback). LMS behandelt es wie Internet-Radio. Siehe AD-06. | MUST | Spotty-NG v2/v3, Herger-Feedback |
| CON-13 | **Position-Sync bei Seek/Mid-Song-Connect**: ProgBar muss korrekte Position zeigen wenn Spotify App seeked oder User mid-song zu einem Player wechselt. Über `startOffset` oder HTTP Content-Range. | MUST | Spotty-NG v3.1 |
| CON-14 | **Sink-Level Rate-Limiting**: Binary darf Audio nicht schneller als Echtzeit dekodieren — Spirc meldet sonst falsche Positionen an Spotify Cloud. Nanosekunden-genaues Wall-Clock-Limiting im Sink. | MUST | Spotty-NG v2, P-16 |
| CON-15 | **Differentieller Daemon-Restart bei Sync-Changes**: Nur betroffene Daemons stoppen/starten. Restart-Counter bei Sync-Stop resetten. FIFO/Cache bei Sync erhalten. | MUST | Spotty-NG v3.0, P-17 |
| CON-16 | **Gapless Connect-Playback**: Sink bleibt über Track-Grenzen hinweg aktiv (`StdoutStreamSink::stop()` beendet den Prozess nicht). Track-Transitions kommen als `change`-Events. | SHOULD | Spotty-NG v2 |
| CON-17 | **Keine `['time', N]`-Requests in Stream-Mode**: Position-Sync ausschließlich über `startOffset`. Siehe P-13. | MUST | Spotty-NG v3.1 (kritischer Bugfix) |

### 3.4 Authentication & Token Management

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| AUT-01 | **OAuth 2.0 Authorization Code + PKCE** als einziger Auth-Mechanismus: Browser-basierte Autorisierung mit code_verifier/code_challenge, jeder User registriert eigene Spotify Developer App (D-04) | MUST | Phase 02.1 |
| AUT-02 | **Token Caching + Auto-Refresh**: Access Token cachen, bei Ablauf automatisch refreshen, kein User-Eingriff bei normalem Betrieb | MUST | Token.pm |
| AUT-03 | **Multi-Account-Support**: Mehrere Spotify-Accounts pro LMS-Instanz | SHOULD | Herger's AccountHelper |
| AUT-04 | **ENTFAELLT** — login5 ist von Spotify deaktiviert (verifiziert Mai 2026). Kein Fallback-Mechanismus. Siehe Phase 02.1 D-01/D-02. | REMOVED | Phase 02.1 D-01/D-02 |
| AUT-05 | **Scope-Management**: Alle benötigten Scopes (`user-library-read`, `user-read-playback-state`, `streaming`, etc.) bei Erstanmeldung anfordern | MUST | Token.pm `SPOTIFY_SCOPE` |
| AUT-06 | **Client-ID-Strategie**: Jeder User registriert eigene Spotify Developer App. Keine bundled Client-ID, keine zentrale Plugin-ID. Client-ID wird in LMS-Settings eingegeben (D-04). | MUST | Phase 02.1 D-04 |

### 3.5 LMS Integration

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| LMS-01 | **Protocol Handler**: `spotify://` URIs registrieren und abspielen | MUST | ProtocolHandler.pm |
| LMS-02 | **Settings UI**: Web-basierte Konfiguration unter LMS Settings | MUST | HTML::Settings |
| LMS-03 | **Strings/i18n**: Mindestens EN + DE, via LMS-Strings-Mechanismus | MUST | strings.txt |
| LMS-04 | **Don't Stop The Music**: Integration mit LMS DSTM für Auto-Play nach Playlist-Ende | SHOULD | Herger's DSTM-Integration |
| LMS-05 | **install.xml Manifest**: Korrekte Plugin-Metadaten, minVersion, Repository-URL für auto-update | MUST | LMS-Konvention |
| LMS-06 | **Multi-Architektur Binaries**: Vorgefertigte librespot-Binaries für x86_64, i386, aarch64, armhf | MUST | Herger's `Bin/` Verzeichnisstruktur |
| LMS-07 | **Custom Binary Support**: User kann eigene Binary bereitstellen (`spotty-custom` Override) | SHOULD | Helper.pm Lookup-Reihenfolge |
| LMS-08 | **Binary Capability Detection**: Plugin fragt Binary nach Fähigkeiten (`--check` JSON) und passt Features an | MUST | Helper.pm `getCapability` |
| LMS-09 | **Player-spezifische Prefs**: Bitrate, Volume Normalization, Connect On/Off — pro Player einstellbar | SHOULD | `$prefs->client($client)` |
| LMS-10 | **Kompatibilität LMS 7.9+**: Mindestens ab Version 7.9 lauffähig, volle Features ab 8.5.1 | SHOULD | Herger's Versionsweichen |

## 4. Nicht-Funktionale Anforderungen

### 4.1 API Rate Limiting (die zentrale Lektion)

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| NFL-01 | **Sequenzielle Pagination mit Backpressure**: NIEMALS alle Seiten parallel feuern. Maximal 2-3 gleichzeitige Requests, nächste Seite erst nach Response der vorherigen. | MUST | Spotty-NG v1 — DAS Kernproblem |
| NFL-02 | **Proaktive Rate-Limit-Einhaltung**: Nicht erst auf 429 reagieren, sondern Burst verhindern. `Retry-After` respektieren, aber selten dort ankommen. | MUST | Pipeline.pm Redesign |
| NFL-03 | **Request-Throttle als eigenständige Komponente**: Rate Limiting nicht verstreut in 5 Dateien, sondern ein zentraler Throttle, durch den ALLE API-Calls gehen. | MUST | Architektur-Lektion |
| NFL-04 | **Cache-Strategie**: API-Responses cachen mit sinnvollen TTLs (60s für Library, 300s für Browse, 3600s für Metadaten). Cachekeys reproduzierbar. | MUST | API/Cache.pm |

### 4.2 Robustheit

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| NFL-05 | **Daemon Auto-Restart**: Connect-Daemon-Crash → automatischer Neustart mit Backoff (nicht sofort, nicht endlos) | MUST | DaemonManager |
| NFL-06 | **Graceful Degradation**: Wenn Spotify-API nicht erreichbar → Cached Daten zeigen, nicht leer. Wenn Binary fehlt → Connect deaktivieren, Browse weiter ermöglichen. | SHOULD | UX |
| NFL-07 | **Sauberes Shutdown**: Bei LMS-Stop alle Daemons sauber beenden, keine Zombies | MUST | Phase 8 REG-01 |
| NFL-08 | **Log-Hygiene**: Strukturierte Logs unter eigenem Log-Category. Kein Spam im Normalbetrieb, ausreichend Detail bei DEBUG. | SHOULD | Herger loggt zu viel bei WARN |

### 4.3 Wartbarkeit

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| NFL-09 | **Klare Modul-Grenzen**: Jedes `.pm`-File hat eine Aufgabe. Kein 1455-Zeilen-Monolith wie Herger's `API.pm`. | SHOULD | Architektur |
| NFL-10 | **Testbarkeit**: Kern-Logik (Pagination, Token-Refresh, Event-Parsing) soll Unit-testbar sein, soweit in Perl-Plugin-Kontext möglich | SHOULD | Qualität |

## 5. Architektur-Entscheidungen zum Treffen

Diese sind noch offen und brauchen bewusste Entscheidungen:

### AD-01: OAuth-Strategie

**Optionen:**
1. **PKCE-only** — wie Herger, bewährt, braucht Browser-Redirect
2. **login5/Keymaster-primary** — kein Browser-Redirect nötig, aber internes Spotify-Protokoll (Risiko: kann brechen)
3. **Hybrid** — Keymaster als Default, PKCE als Fallback (wie Spotty-NG v2)

**Spotty-NG-Erfahrung:** Hybrid funktioniert, aber erhöht Komplexität. Keymaster eliminiert die Developer-App-ID-Problematik und den Browser-Flow.

### AD-02: Client-ID-Modell

**Optionen:**
1. **Eigene Dev App ID required** — User muss App bei Spotify registrieren
2. **Bundled ID** — Plugin bringt eine mit (Risiko: Rate-Limits geteilt mit allen Nutzern; Spotify kann sperren)
3. **Konfigurierbar** — Default bundled, Override möglich
4. **Keine ID nötig** — wenn Keymaster/login5 als Primary Auth (Token kommt vom Binary)

**Spotty-NG-Erfahrung:** Dual-Flavor (eigene für `me/*`, bundled für `browse/*`) war ein Workaround. Sauberer: eine Strategie.

### AD-03: Pipeline-Architektur

**Optionen:**
1. **Strikt sequenziell** — ein Request nach dem anderen, simpel aber langsam
2. **Sliding Window** — max N gleichzeitige Requests (z.B. 3), nächster startet wenn einer fertig
3. **Adaptive** — startet sequenziell, beschleunigt wenn kein 429 kommt

**Spotty-NG-Erfahrung:** Herger feuerte bis zu 30 parallele Requests → 429-Burst. Schon 3 sequenzielle wären ausreichend schnell.

### AD-04: Binary-Beziehung

**Optionen:**
1. **Fork von Herger's librespot** — wie Spotty-NG, `--single-track`, `--check`, `--lms-auth` etc.
2. **Fork von librespot-org** mit eigener LMS-Glue — wie Spotty-NG Plan B (hat gewonnen!)
3. **Upstream-kompatibles Binary** — nur Features nutzen die in librespot-org sind, Glue in Perl

**Spotty-NG-Erfahrung:** Plan B (eigene LMS-Glue auf librespot-org-Basis) war robuster und verständlicher als Herger's gewachsener Fork.

### AD-05: Transcoding-Strategie

**Das OGG-Problem:**
- Spotify liefert intern Vorbis in einem OGG-Container
- librespot dekodiert zu Raw PCM (S16LE, 44100 Hz, Stereo) und schreibt nach stdout
- LMS braucht ein deklariertes Source-Format für die Transcoding-Pipeline
- Herger deklariert `spt` als Custom-Format in `custom-convert.conf`
- Ziel-Formate: PCM (direkt), FLAC (via `flac`-Binary), MP3 (via `lame`-Binary)

**Optionen:**
1. **Wie Herger** — Custom `spt`-Format, `custom-convert.conf` mit 3 Pipelines
2. **Direkter PCM-Passthrough** — librespot gibt immer PCM aus, Plugin deklariert `pcm` als Source
3. **OGG-Direct-Modus** — für Player die OGG nativ können (spart Transcoding)

**Überlegung:** Welche Player können OGG direkt? Welche brauchen FLAC? Welche nur MP3? Das muss per Player-Capability entschieden werden.

### AD-06: Connect-Audio-Transport — FIFO vs. HTTP-Streaming

> Zentrale Architektur-Entscheidung, informiert durch Spotty-NG v3.0/v3.1 Erfahrungen und Herger's Feedback.

**Problem:** Wie kommt Audio vom Connect-Daemon (librespot) zum LMS-Player?

**Option A: Named Pipe / FIFO** (Spotty-NG v2/v3 Ansatz)
- Binary schreibt PCM nach stdout, Shell-Redirect zu Named Pipe (`> /tmp/spotty-stream-*.pcm`)
- LMS liest via `[cat] $FIFO$` in custom-convert.conf (`# R` = Remote Streaming)
- LMS behandelt den Stream wie Internet-Radio (`isRepeatingStream(1)`)

| Pro | Contra |
|-----|--------|
| Simpel, funktioniert, kein HTTP-Server im Binary nötig | ~5-10s ProgBar-Lag nach Seek (Pipeline-Buffer-Latenz) |
| Multiroom nativ (LMS nextChunk verteilt an Sync-Buddies) | Intermittierendes White Noise bei Reconnect (Reader/Writer-Transition) |
| Gapless Playback funktioniert | Position-Sync nur via `startOffset`-Workaround (P-13) |
| Kein Netzwerk-Overhead (lokale Pipe) | FIFO kann nicht sicher von Perl geflusht werden (P-14) |

**Option B: HTTP-Streaming** (Herger's Vorschlag, 2026-05-21)
- Binary betreibt eingebetteten HTTP-Server auf localhost (z.B. `hyper` oder `tiny_http` in Rust)
- LMS konsumiert den Stream wie Internet-Radio über HTTP
- Transport-Kontrolle bleibt vollständig bei Spotify (Spirc im Binary)
- LMS leert nur Buffers bei Track-Changes und stellt Lautstärke ein

| Pro | Contra |
|-----|--------|
| Saubere Connection-Semantik (kein SIGPIPE-Risiko) | Erfordert HTTP-Server im Rust-Binary (signifikante Arbeit) |
| Content-Range/ICY für Position- und Metadata-Sync | Netzwerk-Overhead (loopback, aber trotzdem TCP) |
| Kein Pipeline-Buffer-Problem bei Seek | Komplexerer Binary-Build |
| LMS hat bewährte HTTP-Radio-Infrastruktur | Muss für alle Target-Architekturen kompilieren |

**Spotty-NG-Erfahrung:**
- FIFO funktioniert für ~90% der Fälle. Die verbleibenden 10% (Seek-Latenz, Reconnect-White-Noise) sind architektonisch bedingt und nicht von der Perl-Seite lösbar.
- `startOffset`-Adjustments sind ein brauchbarer Workaround für Position-Sync, aber fragil.
- Herger's HTTP-Vorschlag ist die sauberere Architektur. Für SpotOn sollte HTTP-Streaming das Ziel sein.

**Empfehlung:** HTTP-Streaming als primärer Transport für SpotOn. FIFO als Fallback-Option für den Fall dass der HTTP-Server-Code noch nicht fertig ist.

### AD-07: Plugin-Name & Namespace

- Muss anders heißen als `Spotty` (Herger's Trademark quasi)
- `Plugins::SpotOn::Plugin` als Perl-Namespace
- Eigener GUID in install.xml
- Eigene Prefs-Datei
- Koexistenz mit installiertem Spotty möglich? Oder Ersatz?

## 6. Bekannte Pitfalls & Lessons Learned

### P-01: 429-Burst durch parallele Pagination
**Problem:** Herger's `Pipeline._followOffset` feuert alle Offset-Seiten gleichzeitig. Bei 1500 Liked Songs = 30 parallele Requests → sofortige 429.
**Lösung:** Sliding-Window oder strikt sequenzielle Pagination. Zentrale Throttle-Komponente.

### P-02: OAuth Dual-Flavor-Dispatch
**Problem:** Herger's bundled Client-ID hatte zu wenig Scopes für `me/*`. Eigene Developer-App-ID nötig für Library-Zugriff, bundled für Browse.
**Lösung:** Von Anfang an klare Client-ID-Strategie. Wenn möglich: eine ID für alles, oder Keymaster-basiert ohne ID.

### P-03: `killHangingProcesses` killt Connect-Daemons
**Problem:** LMS hat einen internen Cron der Zombie-Prozesse killt. Der sieht Connect-Daemons als "hängende" spotty-Prozesse und killt sie.
**Lösung:** Guard-Funktion die Connect-Daemon-PIDs vom Zombie-Killer ausnimmt.

### P-04: Streaming/Connect Mutual Exclusion
**Problem:** Wenn ein User über Browse streamt UND Connect aktiv ist, können sich die Sessions gegenseitig invalidieren (Spotify erlaubt nur eine aktive Session pro Account).
**Lösung:** Explizite State-Machine die weiß ob gerade Connect oder Browse-Streaming aktiv ist. Bei Konflikt: klare Priorität.

### P-05: Connect Volume-Sprünge
**Problem:** Beim Connect-Start sendet das Binary initiale Volume-Events die den LMS-Player-Lautstärke auf den Spotify-Wert setzen → unerwartete Lautstärke-Sprünge.
**Lösung:** Volume-Suppression-Window nach Connect-Start (erste N Sekunden oder bis erstes Play-Event).

### P-06: LMS-Log-Datumsformat
**Problem:** LMS loggt mit `[YY-MM-DD HH:MM:SS.SSSS]` (zweistelliges Jahr), nicht ISO 8601. Monitoring-Skripte die `YYYY-MM-DD` matchen finden nichts.
**Lösung:** Log-Parser müssen das LMS-Format kennen.

### P-07: `lms-community` OAuth Relay
**Problem:** Der lms-community OAuth-Relay (für Plugin-basierte Auth) strippt den `state`-Parameter. `codeExchange` braucht spezielle Behandlung.
**Lösung:** Eigenen `state`-Parameter über `_client_id`-Propagation im Token-Flow mitführen.

### P-08: Cache-Key-Hashing
**Problem:** `Slim::Utils::Cache` (DbCache) hasht Keys zu Dezimal-Integers. Kollisionen bei ähnlichen Keys möglich.
**Lösung:** Cache-Keys mit ausreichend Entropie generieren (MD5-Hash des vollen Keys).

### P-09: Transcoding-Tabelle ist global mutable
**Problem:** `updateTranscodingTable` modifiziert die globale LMS Transcoding-Tabelle per Regex-Replace zur Laufzeit. Bei mehreren Accounts/Playern überschreiben sich die Cache-Pfade.
**Lösung:** Pro-Request Cache-Folder-Injection, nicht globale Mutation. Oder: pro Player eigene Transcoding-Regel.

### P-10: Binary-Kompatibilität zwischen Versionen
**Problem:** `--check` JSON-Capabilities können sich zwischen librespot-Versionen ändern. Plugin muss graceful damit umgehen wenn Keys fehlen oder sich ändern.
**Lösung:** Capability-Queries mit Defaults versehen. Nie hart auf spezifische Keys prüfen ohne Fallback.

### P-11: Pi Cross-Compilation
**Problem:** aarch64-musl-Target braucht `cross-rs/cross` mit Podman/Docker. Native Compile auf dem Pi ist zu langsam.
**Lösung:** Cross-Compile-Setup als dokumentiertes Verfahren, nicht Ad-hoc.

### P-12: featured-playlists 404
**Problem:** Spotify gibt intermittierend 404 für `browse/featured-playlists` zurück. Beim zweiten Request funktioniert es. Bekannt aus v1 und heute wieder im Pi-Log gesehen.
**Lösung:** Retry-on-404 für bestimmte Browse-Endpoints, oder Cache aus letztem erfolgreichen Call verwenden.

### P-13: LMS `['time', N]` löst Stream-Restart aus (KRITISCH)
**Problem:** `Slim::Control::Request->new($client->id, ['time', N])` geht durch `StreamingController._JumpToTime`. Bei `N==0`: "restart current track" (`_Stop` + `_Stream`). Bei `N>0`: `getSeekData` + `_Stop` + `_Stream`. In stream-mode (FIFO) startet das den gesamten Audio-Pipeline neu → White Noise bei schnellem Skipping, ProgBar-Reset auf 0 bei Seek.
**Lösung:** In stream-mode NIEMALS `['time', N]` verwenden. Stattdessen: `$song->startOffset($targetPosition - $client->songElapsedSeconds())`. Die Formel `songTime = startOffset + songElapsedSeconds` (StreamingController.pm Z.1729+1733) aktualisiert die angezeigte Position ohne die Audio-Pipeline zu berühren. `songElapsedSeconds` kommt vom Slimproto Hardware-Counter — kein Perl-Setter existiert. `remoteStreamStartTime` ist nur für SB1-Klasse, wirkungslos für moderne Player.

### P-14: FIFO kann nicht sicher von Perl geflusht werden
**Problem:** Named Pipes haben zwischen Reader-Wechseln ein Fenster wo der Writer kein Gegenüber hat. Versuch, den FIFO non-blocking zu lesen und zu schließen (`sysopen O_RDONLY|O_NONBLOCK`, `sysread`, `close`), sendet SIGPIPE an den Binary-Writer → Stream-Korruption.
**Lösung:** Kein FIFO-Flush von Perl aus. HTTP-Streaming würde dieses Problem eliminieren (saubere Connection-Semantik).

### P-15: `_onNewSong` feuert synchron aus `playlist play`
**Problem:** Wenn Connect-Start-Handler `pluginData(progress => $position)` NACH dem `playlist play` Befehl speichert, hat `_onNewSong` den Wert noch nicht — Race Condition. `_onNewSong` wird synchron durch `playlist play` ausgelöst.
**Lösung:** Progress-Wert IMMER VOR dem `playlist play` Befehl in `pluginData` speichern.

### P-16: Rate-Limiting im Sink ersetzt NullSink-Hack
**Problem:** Herger's alter `lms_connect_mode`-Hack unterdrückte `EndOfTrack`-Events an Spirc, damit Spotify nicht sofort den nächsten Track schickt. Funktionierte, war aber ein Workaround.
**Lösung:** Beide Sinks (`ConnectNullSink`, `StdoutStreamSink`) verwenden Nanosekunden-genaues Wall-Clock-Rate-Limiting: `expected_ns = frames_consumed × 1e9 / SAMPLE_RATE`. Spirc meldet realistische Positionen, Spotify denkt nie dass der Track vorzeitig fertig ist. `EndOfTrack` feuert zum korrekten Zeitpunkt.

### P-17: DaemonManager braucht differentiellen Restart bei Sync-Changes
**Problem:** Blinder `shutdown + restart` aller Daemons bei Sync-Group-Änderungen tötet auch unbeteiligte Connect-Sessions. `_startTimes`-Tracking ging durch wiederholte Sync-Cycles verloren → Discovery wurde deaktiviert (Backoff-Limit erreicht).
**Lösung:** Differentieller Restart: nur die betroffenen Daemons stoppen/starten. `_startTimes` bei `stopForSync` resetten (nicht akkumulieren). FIFO und Cache-Dir bei Sync-Stop erhalten.

### P-18: Stream-Mode Multiroom funktioniert nativ
**Problem:** Unklar ob FIFO-basiertes Audio für Multiroom-Sync taugt.
**Lösung:** Bestätigt: `Slim::Player::Source::nextChunk` liest vom Sync-Master-Stream und pusht Chunks nativ an alle Sync-Buddies. LMS behandelt `cat $FIFO$` identisch zu einem Internet-Radio-Stream. Kein HTTP-Wrapper nötig. `isRepeatingStream(1)` verhindert dass LMS das Stream-Ende als Track-Ende interpretiert.

### P-19: Stream-Mode Seek hat ~5-10s Pipeline-Latenz
**Problem:** Nach einem Seek via Spotify App zeigt der LMS-ProgBar die korrekte Position (dank `startOffset`), aber der Audio-Output hinkt ~5-10 Sekunden hinterher — alte Daten im FIFO/Decoder/Output-Buffer müssen erst abgespielt werden.
**Lösung:** Architektonisch bedingt durch FIFO. Nur mit HTTP-Streaming vollständig lösbar (kein Pipeline-Buffer zwischen Binary und LMS).

### P-20: Intermittierendes White Noise bei FIFO-Reconnect
**Problem:** Gelegentlich White Noise wenn der User zu einem Player zurückwechselt (Disconnect → Forward-Seek → Reconnect). Wahrscheinlich PCM-Frame-Alignment-Problem bei der FIFO Reader/Writer-Transition, oder Binary-Decoder im Übergangszustand.
**Lösung:** Nicht von Perl-Seite fixbar. Erfordert Binary-seitigen Fix (Silence-Marker am Stream-Anfang) oder HTTP-Streaming.

## 7. OGG/Transcoding — Deep Dive (per User-Hinweis)

### Warum das kritisch ist

Spotify's Audio-Pipeline:
1. Spotify speichert Tracks als **Ogg Vorbis** (96/160/320 kbps)
2. librespot empfängt den Vorbis-Stream und **dekodiert zu Raw PCM** (S16LE, 44100 Hz, 2ch)
3. Das PCM wird nach stdout geschrieben
4. LMS liest stdout und transcoded je nach Player-Capability:
   - **PCM direkt** → für Player die Raw-Audio können (Squeezebox Touch, etc.)
   - **FLAC-Wrapping** → `flac -cs` komprimiert verlustfrei für Netzwerk-Effizienz
   - **MP3-Encoding** → `lame` für ältere Player die nur MP3 können

### Herger's Umsetzung (custom-convert.conf)

```
spt pcm * *    → spotty --single-track → Raw PCM direkt
spt flc * *    → spotty --single-track | flac -cs → FLAC-komprimiert
spt mp3 * *    → spotty --single-track | lame → MP3
```

- `spt` ist ein Custom-Quellformat (nicht in LMS eingebaut)
- LMS wählt automatisch die beste Pipeline basierend auf Player-Capabilities
- Das `R` in `# R...` aktiviert Seeking, `B` erlaubt Bitrate-Auswahl, `T` erlaubt Start-Position

### Was neu zu bedenken ist

- **OGG-Direct-Modus**: Herger's Binary hatte `--ogg-direct` um den rohen Vorbis-Stream ohne Dekodierung durchzureichen. Das spart CPU auf schwachen Geräten (Pi Zero). Aber: nicht alle Player können OGG. Muss per Player-Cap entschieden werden.
- **FLAC als Default**: Die meisten modernen Squeezebox-Player (Touch, Radio, Boom, piCorePlayer) können FLAC nativ. FLAC als Default-Pipeline ist sinnvoll.
- **MP3 nur als Fallback**: Für SB Classic, SB1 und andere Legacy-Player.
- **Bitrate-Reporting**: LMS will wissen welche Bitrate der Track hat (für die UI). Bei Spotify ist das fix (96/160/320) — muss korrekt reported werden.
- **Seeking**: `--start-position` in Sekunden. LMS übergibt das als `$START$` Substitution in der convert.conf.

## 8. Vorgeschlagene Modul-Struktur (Strawman)

```
Plugins/SpotOn/
├── Plugin.pm              # Hauptmodul, init, Menu-Registrierung
├── ProtocolHandler.pm     # spotify:// URI Handler
├── Settings.pm            # Web-UI Settings
├── strings.txt            # i18n
├── install.xml            # Plugin-Manifest
├── custom-convert.conf    # Transcoding-Pipelines
│
├── API/
│   ├── Client.pm          # Zentraler HTTP-Client mit Throttle
│   ├── Auth.pm            # OAuth PKCE + Token Refresh + Keymaster
│   ├── Browse.pm          # browse/*, search, new-releases
│   ├── Library.pm         # me/tracks, me/albums, me/playlists
│   ├── Player.pm          # me/player, playback state
│   └── Cache.pm           # Response-Caching
│
├── Connect/
│   ├── Manager.pm         # Daemon Lifecycle, Sync-Group-Logic
│   ├── Daemon.pm          # Ein Daemon-Prozess (start/stop/monitor)
│   └── EventHandler.pm    # JSON-RPC Event-Dispatch
│
├── Helper.pm              # Binary-Discovery, --check, Capabilities
├── AccountHelper.pm       # Multi-Account, Credentials
├── Importer.pm            # Online Library Scanner (optional)
│
└── Bin/
    ├── i386-linux/
    ├── x86_64-linux/       # ← eigenes Verzeichnis statt Suffix-Hack
    ├── aarch64-linux/
    ├── arm-linux/
    ├── darwin/
    └── win32/
```

**Kernänderungen vs Herger:**
- `API/Client.pm` als **einziger** HTTP-Ausgang — hier sitzt der Throttle. Niemand ruft `SimpleAsyncHTTP` direkt.
- `API.pm` aufgespalten in `Browse.pm`, `Library.pm`, `Player.pm` statt 1455-Zeilen-Monolith.
- Connect als eigenes Subpackage mit klarer Trennung Manager/Daemon/Events.
- `x86_64-linux/` als eigenes Verzeichnis statt `i386-linux/spotty-x86_64` Suffix-Hack.

## 9. Spotify HiFi / Lossless Audio

> Recherche-Stand: 2026-05-19. Quellen: librespot-org/librespot#1583, Spotify Community, What Hi-Fi, Hit Channel.

### Status

Spotify hat **Lossless Audio im September 2025** für alle Premium-Abonnenten gelauncht (kein Aufpreis). Verfügbar in 50+ Ländern inkl. Deutschland.

### Audio-Format

- **FLAC**, bis zu **24-bit / 44.1 kHz** (CD-Qualität lossless)
- Ersetzt das bisherige Maximum von 320 kbps Ogg Vorbis ("Very High")
- Kein Hi-Res (96/192 kHz), kein Spatial Audio (Dolby Atmos)

### librespot-Unterstützung: BLOCKIERT

**librespot kann und wird Lossless nicht unterstützen.** Die Gründe (dokumentiert in librespot-org/librespot#1583):

1. Die FLAC-Dateien selbst werden wie Vorbis ausgeliefert (gleicher CDN, gleiche AES-128-CTR-Verschlüsselung)
2. Die Protobuf-Format-Werte sind bekannt: `FLAC` (16), `FLAC_24` (22)
3. **ABER**: Spotify hat die Entschlüsselungs-Keys für Lossless hinter ihr **PlayPlay DRM**-System gelegt. Das alte Shannon-Protokoll (das librespot nutzt) funktioniert nur noch für lossy (Vorbis) Streams.
4. PlayPlay nutzt White-Box-Kryptographie (ähnlich Widevine). Spotify hat DMCA-Takedowns gegen jede Veröffentlichung von Keys durchgesetzt.
5. **Die librespot-Maintainer haben direkte Kommunikation von Spotify erhalten**, die klarstellt, dass eine Umgehung von PlayPlay das gesamte Projekt gefährden würde.

### Auswirkungen auf SpotOn

| Aspekt | Status | Risiko |
|---|---|---|
| Lossy Streaming (320 kbps Vorbis) | Funktioniert via Shannon-Protokoll | NIEDRIG — Spotify hält Shannon am Leben wegen zertifizierter Connect-Hardware (Sony, Bose etc.) |
| Lossless Streaming via librespot | **Unmöglich** ohne PlayPlay-DRM | Nicht umsetzbar ohne Spotify-Kooperation |
| Shannon-Deprecation | Theoretisch möglich | MITTEL — wenn Spotify Shannon komplett auf PlayPlay migriert, stoppt librespot insgesamt |
| Web API (Browse/Library) | Nicht betroffen | KEIN RISIKO — Lossless ist eine Playback-Layer-Frage |

### Requirements

| ID | Requirement | Priorität | Herkunft |
|---|---|---|---|
| HIF-01 | **Architektur muss Lossless-Erweiterung ermöglichen**: Audio-Pipeline nicht auf Vorbis hardcoden. Wenn librespot eines Tages FLAC liefert, muss die Pipeline es durchreichen können. | SHOULD | Zukunftssicherheit |
| HIF-02 | **Bitrate/Qualitätsstufen-Abstrahierung**: Nicht `96/160/320` hardcoden, sondern ein Quality-Enum das "Lossless" aufnehmen kann | SHOULD | Forward-Compatibility |
| HIF-03 | **Monitoring des Shannon-Status**: Beobachten ob Spotify Shannon weiter unterstützt. Bei Anzeichen einer Migration frühzeitig reagieren. | SHOULD | Risikomanagement |
| HIF-04 | **Kein PlayPlay-DRM-Reverse-Engineering**: Explizites Verbot. Keine Workarounds, die Spotify's Rechte oder librespot's Existenz gefährden. | MUST | Legal + Ethik |

### Fazit

Lossless ist **kurzfristig nicht erreichbar**, aber wir können die Architektur so bauen, dass sie bereit ist falls sich die Lage ändert (z.B. offizielle SDK für Drittanbieter-Connect, Spotify öffnet Lossless für Open-Source-Implementierungen). 320 kbps Vorbis bleibt vorerst das Maximum.

## 10. Spotify Developer Guidelines & Compliance

> Quelle: developer.spotify.com/documentation/design, /commercial-hardware, /web-api

### 10.1 Branding & Attribution (MUST-Regeln)

| ID | Requirement | Priorität | Quelle |
|---|---|---|---|
| SPD-01 | **Spotify-Logo/Icon bei allen Inhalten**: Jeder über Spotify geladene Content muss mit dem Spotify-Brand gekennzeichnet sein | MUST | Design Guidelines |
| SPD-02 | **Metadaten unverändert anzeigen**: Track-, Artist-, Album-, Playlist-Titel exakt wie von Spotify geliefert. Truncation erlaubt, Manipulation nicht. | MUST | Design Guidelines |
| SPD-03 | **Rückverlinkung**: Spotify-Metadaten müssen zurück zum Spotify-Service verlinken ("Play on Spotify", "Open Spotify") | MUST | Design Guidelines |
| SPD-04 | **Artwork unverändert**: Nicht croppen, animieren, verzerren, oder mit Text/Logo überlagern. Eckenradius: 4px klein/mittel, 8px groß. | MUST | Design Guidelines |
| SPD-05 | **Plugin-Name darf nicht "Spotify" enthalten** oder klanglich ähnlich sein. "for Spotify" als Untertitel ist erlaubt. | MUST | Design Guidelines |
| SPD-06 | **Keine Co-Branding-Kommunikation** mit dem Spotify-Brand | MUST | Developer Terms |
| SPD-07 | **Explicit Content Badge**: Für explizite Tracks/Episoden anzeigen (besonders für südkoreanische User Pflicht) | SHOULD | Design Guidelines |

### 10.2 Playback UI Guidelines

| ID | Requirement | Priorität | Quelle |
|---|---|---|---|
| SPD-08 | **Spotify empfiehlt nur Play/Pause** als Playback-Controls in Drittanbieter-Apps. Grund: Free-Tier kann Skip/Seek nicht immer → verwirrende UX | SHOULD | Design Guidelines |
| SPD-09 | **PlaybackRestrictions beachten**: Deaktivierte Controls visuell als disabled darstellen oder ausblenden | SHOULD | Design Guidelines |
| SPD-10 | **Podcast-Seeking**: 15s vorwärts/rückwärts muss unterstützt werden | SHOULD | Design Guidelines |
| SPD-11 | **Liked Songs / Like-Button**: Signal geht zurück an Spotify. Gelikte Inhalte dürfen NICHT lokal gespeichert werden. | MUST | Design Guidelines |
| SPD-12 | **Artwork-Farbe für Hintergrund extrahieren**, Fallback: `#191414` | SHOULD | Design Guidelines |

### 10.3 Content Browsing Rules

| ID | Requirement | Priorität | Quelle |
|---|---|---|---|
| SPD-13 | **Spotify bestimmt Content-Kategorien**: Nicht manuell kuratieren oder manipulieren | MUST | Design Guidelines |
| SPD-14 | **Max 20 Items pro Content-Set** in einer Shelf/Liste | MUST | Design Guidelines |
| SPD-15 | **Spotify-Inhalte nicht neben Konkurrenz-Services** platzieren | MUST | Design Guidelines |
| SPD-16 | **Link am Ende jeder Kategorie** zum Entdecken in der Spotify-App | SHOULD | Design Guidelines |

### 10.4 Web API Quota & Rate Limits

| ID | Requirement | Priorität | Quelle |
|---|---|---|---|
| SPD-17 | **Rate Limit: Rolling 30-Sekunden-Fenster**, app-weit (nicht pro User oder Endpoint) | MUST | Web API Docs |
| SPD-18 | **429 + `Retry-After` Header respektieren**: Warten, dann retry | MUST | Web API Docs |
| SPD-19 | **Batch-APIs nutzen** wo verfügbar (Get Multiple Albums, Get Multiple Tracks etc.) | SHOULD | Web API Best Practices |
| SPD-20 | **`snapshot_id` für Playlists**: Unnötige Refreshes vermeiden | SHOULD | Web API Best Practices |
| SPD-21 | **Lazy Loading**: Features erst bei User-Interaktion laden, nicht alles beim Start | SHOULD | Web API Best Practices |
| SPD-22 | **Development Mode**: Max 5 authentifizierte User, App-Owner braucht Premium | MUST | Quota Modes |
| SPD-23 | **Extended Quota Mode** beantragen wenn >5 User: Partner Application + Review (bis 6 Wochen) | SHOULD | Quota Modes |

### 10.5 Commercial Hardware / Spotify Connect (eSDK)

| Aspekt | Status | Relevanz für SpotOn |
|---|---|---|
| **eSDK (Embedded SDK)** | Nur für "approved partners" (Organisationen), NDA + Zertifizierung via Certomato | Nicht direkt nutzbar — SpotOn nutzt librespot, nicht eSDK |
| **Offizielle Connect-Zertifizierung** | Erfordert Geräte-Einreichung bei Spotify | Nicht anwendbar für Open-Source-Software-Plugin |
| **ZeroConf API** | Dokumentiert für Connect-Discovery | Relevant — librespot implementiert ZeroConf bereits |
| **Media Delivery API** | Dokumentiert für Audio-Streams | Hinter NDA, nicht öffentlich zugänglich |

**Einordnung:** SpotOn operiert — wie alle librespot-basierten Projekte — außerhalb des offiziellen Spotify-Partner-Programms. Die Design-Guidelines sind trotzdem als Best-Practice-Orientierung wertvoll, auch wenn keine formale Compliance-Pflicht besteht (da kein eSDK-Vertrag).

### 10.6 Applicability Assessment

> **Ehrliche Einordnung:** SpotOn ist ein Open-Source-Community-Plugin, kein zertifiziertes Spotify-Partner-Produkt. Viele der oben genannten SPD-Requirements sind formal nur für eSDK-Partner bindend. Trotzdem sollten wir sie als **Qualitätsstandard** behandeln — wer die Spotify-UX-Konventionen respektiert, liefert eine bessere User-Experience und minimiert rechtliche Risiken.
>
> **Realistische Compliance-Stufen:**
> - **Voll anwendbar:** Metadaten-Anzeige, Attribution, Artwork-Behandlung, Rate Limits, Batch-APIs
> - **Bestmöglich umsetzen:** Branding (Logo in LMS-OPML begrenzt möglich), Content-Regeln
> - **Nicht anwendbar:** eSDK-Zertifizierung, Certomato, Hardware-Anforderungen, Partner-NDA
> - **Bewusst ignoriert:** "Nur Play/Pause"-Empfehlung (LMS-Player haben volle Kontrolle und Premium ist Voraussetzung)

## 11. Offene Fragen an dich

1. ~~**Name?**~~ → **SpotOn** ✓
2. **Koexistenz mit Spotty?** — Soll SpotOn neben Herger's Spotty installierbar sein, oder ist es ein Ersatz?
3. **Minimale LMS-Version?** — Herger supported ab 7.7. Wollen wir den Floor höher setzen (z.B. 8.5.1+) um Legacy-Codepfade zu vermeiden?
4. **OGG-Direct als Feature?** — Soll der OGG-Passthrough für fähige Player implementiert werden?
5. **Autoplay/DSTM Priorität?** — Ist Don't Stop The Music ein MUST oder SHOULD?
6. **Welche Conversion-Pipelines aus deiner Erfahrung mit deinen Playern — welche Player brauchen welches Format?**
7. **Soll das librespot-Binary im selben Repo leben (Monorepo) oder als separates Projekt?**
8. **Spotify-Branding-Level**: Wollen wir die SPD-Guidelines voll umsetzen (Logo, Attribution, Artwork-Regeln) oder pragmatisch-minimal?
9. **Development Mode reicht?** — Wenn wir im Development Mode bleiben (max 5 User), brauchen wir keinen Extended-Quota-Antrag. Aber: jeder SpotOn-Nutzer müsste seine eigene Spotify Developer App registrieren. Akzeptabel?

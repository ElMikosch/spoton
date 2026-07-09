---
quick_id: 260709-bsx
description: "Diagnostik + Daemon-Stabilität Verbesserungen"
date: 2026-07-09
tasks: 4
---

# Quick Task 260709-bsx: Diagnostik + Daemon-Stabilität

## Task 1: Toten browse-errors.log Bezug entfernen

**Files:** `Plugins/SpotOn/Settings.pm`
**Action:** Drei Stellen bereinigen:
1. `_diagnosticBundleHandler` (Zeile 422-429): "Browse Errors" Sektion komplett entfernen
2. `_clearLogsHandler` (Zeile 488-494): browse-errors.log Lösch-Code entfernen
3. `handler()` (Zeile 224): `'browse-errors.log'` aus dem Log-Größen-Pattern entfernen
**Verify:** `grep -r 'browse-errors' Plugins/` zeigt keine Treffer mehr
**Done:** Datei wird nie geschrieben, dead code entfernt

## Task 2: Token-Status in Diagnostic Report aufnehmen

**Files:** `Plugins/SpotOn/Settings.pm`
**Action:** In `_diagnosticBundleHandler`, nach der "Players" Sektion eine neue "Token & API Status" Sektion einfügen:
- Active Account (redacted: erste 4 Zeichen + `****`)
- Display Name aus TokenManager prefs
- API Request Count + 429 Count aus Client::statusSnapshot()
- Rate-Limited Status (own/bundled)
- Token Error History: die letzten Einträge aus Status.pm `_errorHistory()` wo module="Token"

Zugriff auf Daten:
- `Plugins::SpotOn::API::Client->statusSnapshot()` → apiRequestCount, api429Count, rateLimitedOwn, rateLimitedBundled
- `Plugins::SpotOn::Status->getErrors()` oder direkt `_errorHistory()` — braucht public Accessor
- `$prefs->get('activeAccount')` + accounts Hash für displayName

**Status.pm Änderung:** Public Accessor `getErrorHistory()` hinzufügen falls nicht vorhanden (aktuell ist `_errorHistory` private sub).
**Verify:** Diagnostic Report enthält "Token & API Status" Sektion mit realen Werten
**Done:** Diagnostik zeigt sofort ob Tokens funktionieren

## Task 3: Port-Poll-Timeout von 5s auf 10s erhöhen

**Files:** `Plugins/SpotOn/Unified/Daemon.pm`
**Action:**
- Zeile 27-28: Kommentar anpassen: "100 attempts (10s cap)" statt "50 attempts (5s cap)"
- Zeile 30: `PORT_POLL_MAX_ATTEMPTS => 50` → `PORT_POLL_MAX_ATTEMPTS => 100`
**Verify:** `grep PORT_POLL_MAX_ATTEMPTS Plugins/SpotOn/Unified/Daemon.pm` zeigt 100
**Done:** Daemons haben 10s statt 5s für Port-Announce, weniger false-positive Timeouts

## Task 4: Staggered Daemon Start

**Files:** `Plugins/SpotOn/Unified/DaemonManager.pm`
**Action:** In `initHelpers()` (Zeile 223-258) die synchrone Startschleife durch gestaffelte Timer ersetzen:
- Erste Player sofort starten, restliche mit 3s Verzögerung pro Player
- Nur staggern wenn der Daemon für den Player noch NICHT läuft (helperInstance existiert nicht oder ist nicht alive)
- Bereits laufende Daemons nicht antasten (60s-Watchdog soll keine laufenden Daemons neu-staggern)
- `Slim::Utils::Timers::setTimer()` verwenden für verzögerten Start
- STAGGER_DELAY Konstante definieren (3 Sekunden)

**Verify:** Keine Syntax-Fehler, Logik-Review: erster Player sofort, restliche gestaffelt
**Done:** Bei 6 Playern starten Daemons über ~15s verteilt statt alle gleichzeitig

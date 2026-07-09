---
status: complete
---

# Quick Task 260709-bsx: Diagnostik + Daemon-Stabilität — Summary

**Completed:** 2026-07-09
**Commit:** e714019

## Changes

1. **browse-errors.log dead code removed** — 3 references in Settings.pm entfernt (diagnostic bundle, clearLogs handler, log size calculation). Die Datei wurde nie geschrieben.

2. **Token & API Status in Diagnostic Report** — Neue Sektion zeigt Display Name, API Request/429-Zähler, Rate-Limit-Status, und letzte Token-Fehler aus Status.pm Error-History. Public `getErrorHistory()` Accessor in Status.pm hinzugefügt.

3. **Port-Poll-Timeout 5s → 10s** — `PORT_POLL_MAX_ATTEMPTS` von 50 auf 100 erhöht. Reduziert false-positive Timeout-Meldungen auf langsameren Systemen.

4. **Staggered Daemon Start** — Neue `STAGGER_DELAY` Konstante (3s) in DaemonManager.pm. Erster Player startet sofort, restliche mit 3s-Intervall. Bei 6 Playern: ~15s statt alle gleichzeitig. Cancel-Logik für Watchdog-Re-Checks inkludiert.

## Files Modified

- `Plugins/SpotOn/Settings.pm` — browse-errors.log entfernt, Token & API Status hinzugefügt
- `Plugins/SpotOn/Status.pm` — public `getErrorHistory()` Accessor
- `Plugins/SpotOn/Unified/Daemon.pm` — PORT_POLL_MAX_ATTEMPTS 50→100
- `Plugins/SpotOn/Unified/DaemonManager.pm` — STAGGER_DELAY, staggered start loop, _staggeredStart callback

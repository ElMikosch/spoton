---
status: complete
phase: 51-credential-derivation-connect
source: [51-VERIFICATION.md]
started: 2026-07-14T18:35:00Z
updated: 2026-07-14T17:35:00Z
---

## Current Test

[testing complete]

## Tests

### 1. D-01 Lazy Safety-Net — Self-Heal bei fehlender credentials.json
expected: PKCE-Account konfigurieren, credentials.json manuell löschen, dann startHelper triggern (Player connect oder LMS Restart). Log zeigt Lazy-Derivation, credentials.json wird re-derived, Daemon startet und Connect-Device erscheint.
result: pass
evidence: "Log: 'No cached credentials ... deriving from PKCE tokens (D-01 lazy safety-net)' → 'Lazy credential derivation succeeded ... retrying daemon start' — credentials.json re-derived mit auth_type=1, korrektem Username, frischer auth_data. Daemon alive."

### 2. D-03 Crash-triggered Auto-Re-Derive
expected: Daemon-Crash mit Credential-Rejection-String im stderr (z.B. korrupte auth_data). _handleCredentialCrash feuert, credentials.json wird gelöscht, automatisch re-derived, Daemon startet neu — ohne User-Aktion.
result: skipped
reason: "Nicht sauber manuell auslösbar — erfordert Daemon-Crash mit spezifischem librespot-core Rejection-String. Code ist line-by-line verifiziert, Grundmechanismen (Derivation, isCredentialError) unit-getestet."

### 3. D-04 Permanent-Failure Escalation
expected: _handleCredentialCrash mit reason='derivation_failed' (Token vom AP rejected). TokenManager->markNeedsReauth feuert genau einmal, 4-Kanal Re-Auth-Warnung aktiv, Daemon bleibt gestoppt.
result: skipped
reason: "Nicht sauber manuell auslösbar — erfordert AP-Rejection eines gültigen Tokens. Code ist line-by-line verifiziert, markNeedsReauth unit-getestet als Wrapper um bestehenden _markNeedsReauth."

### 4. D-08 Account-Mismatch Repair (Wiring)
expected: credentials.json mit fremdem Username in Account-Cache-Dir schreiben, dann startHelper aufrufen. Log zeigt Mismatch-Detection, credentials.json wird gelöscht (pkce_tokens.json bleibt), Lazy-Re-Derive startet.
result: pass
evidence: "Log: 'Credentials for account 7716**** belong to a different Spotify user — deleting and re-deriving (D-08)' → D-01 → 'Lazy credential derivation succeeded'. Username korrekt repariert (WRONG_USER → 3fiqdghd...), pkce_tokens.json überlebt, Daemon neu gestartet (pid=885502)."

### 5. AUTH-04 End-to-End Connect
expected: Vollständiger Flow: PKCE Auth → Credential-Derivation → Daemon Start → Connect-Device in Spotify App sichtbar → Audio-Playback funktioniert.
result: pass
evidence: "PKCE Auth via callback relay → Token exchange + refresh succeeded → Eager Credentials derivation (auth_type=1) → Daemon start → Connect-Device 'claude' sichtbar in Spotify App → Audio-Playback bestätigt."

## Summary

total: 5
passed: 3
issues: 0
pending: 0
skipped: 2
blocked: 0

## Gaps

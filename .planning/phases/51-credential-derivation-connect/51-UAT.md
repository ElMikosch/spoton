---
status: testing
phase: 51-credential-derivation-connect
source: [51-VERIFICATION.md]
started: 2026-07-14T18:35:00Z
updated: 2026-07-14T18:35:00Z
---

## Current Test

number: 1
name: D-01 Lazy Safety-Net — Self-Heal bei fehlender credentials.json
expected: |
  Log zeigt 'deriving from PKCE tokens (D-01 lazy safety-net)', credentials.json erscheint, Daemon startet, Connect-Device sichtbar in Spotify App.
awaiting: user response

## Tests

### 1. D-01 Lazy Safety-Net — Self-Heal bei fehlender credentials.json
expected: PKCE-Account konfigurieren, credentials.json manuell löschen, dann startHelper triggern (Player connect oder LMS Restart). Log zeigt Lazy-Derivation, credentials.json wird re-derived, Daemon startet und Connect-Device erscheint.
result: [pending]

### 2. D-03 Crash-triggered Auto-Re-Derive
expected: Daemon-Crash mit Credential-Rejection-String im stderr (z.B. korrupte auth_data). _handleCredentialCrash feuert, credentials.json wird gelöscht, automatisch re-derived, Daemon startet neu — ohne User-Aktion.
result: [pending]

### 3. D-04 Permanent-Failure Escalation
expected: _handleCredentialCrash mit reason='derivation_failed' (Token vom AP rejected). TokenManager->markNeedsReauth feuert genau einmal, 4-Kanal Re-Auth-Warnung aktiv, Daemon bleibt gestoppt.
result: [pending]

### 4. D-08 Account-Mismatch Repair (Wiring)
expected: credentials.json mit fremdem Username in Account-Cache-Dir schreiben, dann startHelper aufrufen. Log zeigt Mismatch-Detection, credentials.json wird gelöscht (pkce_tokens.json bleibt), Lazy-Re-Derive startet.
result: [pending]

### 5. AUTH-04 End-to-End Connect
expected: Vollständiger Flow: PKCE Auth → Credential-Derivation → Daemon Start → Connect-Device in Spotify App sichtbar → Audio-Playback funktioniert.
result: [pending]

## Summary

total: 5
passed: 0
issues: 0
pending: 5
skipped: 0
blocked: 0

## Gaps

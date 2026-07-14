---
status: partial
phase: 51-credential-derivation-connect
source: [51-VERIFICATION.md]
started: 2026-07-14T18:35:00Z
updated: 2026-07-14T17:25:00Z
---

## Current Test

[all tests blocked — awaiting PKCE account setup]

## Tests

### 1. D-01 Lazy Safety-Net — Self-Heal bei fehlender credentials.json
expected: PKCE-Account konfigurieren, credentials.json manuell löschen, dann startHelper triggern (Player connect oder LMS Restart). Log zeigt Lazy-Derivation, credentials.json wird re-derived, Daemon startet und Connect-Device erscheint.
result: blocked
blocked_by: prior-phase
reason: "Kein PKCE-Account konfiguriert — PKCE Auth Flow (Phase 50) muss zuerst durchlaufen werden"

### 2. D-03 Crash-triggered Auto-Re-Derive
expected: Daemon-Crash mit Credential-Rejection-String im stderr (z.B. korrupte auth_data). _handleCredentialCrash feuert, credentials.json wird gelöscht, automatisch re-derived, Daemon startet neu — ohne User-Aktion.
result: blocked
blocked_by: prior-phase
reason: "Kein PKCE-Account konfiguriert — benötigt PKCE-Tokens für Re-Derivation"

### 3. D-04 Permanent-Failure Escalation
expected: _handleCredentialCrash mit reason='derivation_failed' (Token vom AP rejected). TokenManager->markNeedsReauth feuert genau einmal, 4-Kanal Re-Auth-Warnung aktiv, Daemon bleibt gestoppt.
result: blocked
blocked_by: prior-phase
reason: "Kein PKCE-Account konfiguriert — benötigt PKCE-Tokens für Failure-Escalation-Test"

### 4. D-08 Account-Mismatch Repair (Wiring)
expected: credentials.json mit fremdem Username in Account-Cache-Dir schreiben, dann startHelper aufrufen. Log zeigt Mismatch-Detection, credentials.json wird gelöscht (pkce_tokens.json bleibt), Lazy-Re-Derive startet.
result: blocked
blocked_by: prior-phase
reason: "Kein PKCE-Account konfiguriert — benötigt existierende PKCE-Tokens im Account-Dir"

### 5. AUTH-04 End-to-End Connect
expected: Vollständiger Flow: PKCE Auth → Credential-Derivation → Daemon Start → Connect-Device in Spotify App sichtbar → Audio-Playback funktioniert.
result: blocked
blocked_by: prior-phase
reason: "Kein PKCE-Account konfiguriert — Test IST der komplette PKCE Auth Flow"

## Summary

total: 5
passed: 0
issues: 0
pending: 0
skipped: 0
blocked: 5

## Gaps

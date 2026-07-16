---
phase: 51
slug: credential-derivation-connect
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-14
---

# Phase 51 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Custom `Test::More` + hand-written LMS-stub harness (Perl `prove`) |
| **Config file** | none — `t/*.t` files are self-contained, each writing its own LMS-module stubs into a `tempdir()` |
| **Quick run command** | `prove t/16_credentials.t` |
| **Full suite command** | `prove t/` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `prove t/16_credentials.t`
- **After every plan wave:** Run `prove t/`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 51-01-01 | 01 | 1 | AUTH-03 | unit (stubbed Proc::Background) | `prove t/16_credentials.t` | ❌ W0 | ⬜ pending |
| 51-01-02 | 01 | 1 | AUTH-03 | unit (lazy path) | `prove t/16_credentials.t` | ❌ W0 | ⬜ pending |
| 51-01-03 | 01 | 1 | AUTH-03 | unit (D-08 mismatch) | `prove t/16_credentials.t` | ❌ W0 | ⬜ pending |
| 51-01-04 | 01 | 1 | AUTH-03 | unit (D-03 stderr regex) | `prove t/16_credentials.t` | ❌ W0 | ⬜ pending |
| 51-02-01 | 02 | 1 | AUTH-04 | regression | `prove t/10_stream_metadata.t` | ✅ | ⬜ pending |
| 51-02-02 | 02 | 1 | AUTH-04 | manual | — | n/a | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `t/16_credentials.t` — new test file covering Credentials.pm (stub `Proc::Background`, `Slim::Utils::Prefs`, `Slim::Utils::Cache`, `Log::Log4perl::Logger`)
- [ ] Add `Plugins/SpotOn/API/Credentials.pm` to `t/05_perl_syntax.t` syntax-check list

*Matches convention from Phase 49: "Added PKCE.pm to t/05_perl_syntax.t syntax-check list"*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Connect device registration + playback with PKCE-derived credentials | AUTH-04 | Requires live Spotify Connect handshake and the Spotify app, not mockable | Use `spoton-uat` or `pi-playback-test` project skill |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

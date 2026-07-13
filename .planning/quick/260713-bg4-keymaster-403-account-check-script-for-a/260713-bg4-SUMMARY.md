---
quick_id: 260713-bg4
status: complete
---

# Quick Task Summary: Keymaster 403 Account Check Script

## What was done
Created `tools/spoton-account-check.sh` — a diagnostic script for users to run
via SSH that determines if their Spotify account is affected by the Keymaster sunset.

## How it works
1. Auto-detects LMS cache directory (common paths + CACHE_DIR env override)
2. Finds the spoton binary (InstalledPlugins, server Plugins dir, PATH)
3. Validates binary with --check
4. Discovers all stored credential directories
5. Runs `spoton --get-token --cache <dir> --client-id <bundled>` per account
6. Interprets output:
   - `accessToken` in response → NOT AFFECTED (green)
   - `status_code: 403` → AFFECTED (red, with explanation)
   - No credentials → guidance to reconnect
   - Other → raw output shown

## Key decisions
- Uses bundled client ID (d420a117...) — same as SpotOn's TokenManager
- Supports all LMS platforms: x86_64, aarch64, armv7, i386
- Color output with clear pass/fail indication
- Links to #91 for tracking

## Commit
Atomic: tools/spoton-account-check.sh created

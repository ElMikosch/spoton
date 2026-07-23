---
status: complete
---

# Phase 57 Plan 03: Upstream Material Skin Issue — Summary

## What Changed

Filed upstream issue at CDrummond/lms-material for the UTF-8 double-encoding bug in `getHomeExtra3rdPartyItems()`.

**Issue:** https://github.com/CDrummond/lms-material/issues/1243

## Root Cause (upstream)

`getHomeExtra3rdPartyItems()` (Plugin.pm:556) returns `to_json()` output (UTF-8 byte string) directly into `$request->addResult()` (Plugin.pm:2049). The outer JSON-RPC serializer re-encodes the bytes → double-encoding mojibake for non-ASCII characters.

## Actions Taken

1. Verified bug still present on MS master (fetched raw Plugin.pm from GitHub)
2. Drafted issue with repro, root cause analysis, and two fix suggestions
3. Developer reviewed and approved draft
4. Posted issue at CDrummond/lms-material#1243

## Files

- `.planning/phases/57-material-skin-ux-polish/upstream-ms-issue-draft.md` — approved draft with filed-as footer

## Decisions

- No SpotOn-side workaround possible — double-encoding happens inside MS after SpotOn's strings leave Slim::Utils::Strings
- Two fix options suggested non-prescriptively (decode output, or skip pre-serialization)

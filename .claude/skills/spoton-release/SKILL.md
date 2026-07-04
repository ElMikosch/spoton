---
name: spoton-release
description: "Prepare and publish a SpotOn release — version bump, CHANGELOG, CI build, repo.xml SHA, docs review, and community follow-up."
---

<objective>
Guide the user through a complete SpotOn release cycle. Every destructive or public-facing step requires explicit user approval. The workflow is dialog-driven: present state, propose actions, get approval, execute.
</objective>

<constants>

## Paths

- **install.xml**: `Plugins/SpotOn/install.xml` (version tag on line 19)
- **repo.xml**: `repo.xml` (version, sha, url)
- **CHANGELOG.md**: `CHANGELOG.md` (Keep a Changelog format)
- **README.md**: `README.md`
- **TROUBLESHOOTING.md**: `TROUBLESHOOTING.md`
- **Cargo.toml**: `librespot-spoton/Cargo.toml` (Rust binary version — independent of plugin version)
- **CI Workflow**: `.github/workflows/build-librespot.yml` (triggers on `v*` tags)
- **Repo**: `stiefenm/spoton`

## Branches

- **main**: hotfixes, current release line
- **v2.3-library**: feature branch for Library Integration phases (37–41)
- Cherry-picks between branches may be needed — always clarify direction with user

## librespot Build Configuration

- Source: `librespot-spoton/` directory in repo
- Upstream: `librespot-org/librespot`, branch `dev` (NOT release tags)
- Local patch: `librespot-discovery-patched/` (IPv6 dual-stack bind fallback)
- CI detects Rust source changes between tags → only rebuilds binaries when `librespot-spoton/` changed
- If only Perl changed: CI reuses binaries from the previous release automatically
- Platforms: x86_64-linux, aarch64-linux, armhf-linux, arm-linux, i386-linux, x86_64-win64, darwin (universal)

## CI Behavior

- **Trigger**: push of `v*` tag
- **Outputs**: individual platform binaries + `SpotOn-vX.Y.Z.zip` (plugin package with all binaries)
- **Release notes**: extracted from CHANGELOG.md automatically
- **SHA1 of zip**: printed in CI output — needed for repo.xml

</constants>

<rules>

## Hard Rules — violating these loses trust

1. **Never set version numbers autonomously.** Always propose and get explicit approval.
2. **Never push tags autonomously.** Present the tag command, get explicit "ja"/"yes".
3. **Never update repo.xml autonomously.** Show the SHA + URL change, get approval, then push.
4. **Never create GitHub Releases manually** — CI does this on tag push. Only verify it completed.
5. **SHA must be fetched fresh from GitHub** — never use a cached/local zip. Download the release asset URL, compute sha1sum on that fresh download.
6. **CHANGELOG must be updated BEFORE the tag is pushed.** The CI extracts notes from CHANGELOG.md at tag-time.
7. **Local test before release.** Verify the fix/feature works on the dev machine before tagging.
8. **No force-push to main.** If something is wrong, revert or create a new tag.
9. **Forum replies via file** — write to `~/SynologyDrive/forum-reply-{post-nr}.txt`. English only.
10. **No auto-close issues.** Even if a fix ships — ask user before closing any issue.

</rules>

<process>

## Phase 1: Assess Current State

### 1.1 Branch and commit status

```bash
git status
git log --oneline -10
git branch -a | grep -E "main|library|release"
```

Present:
- Current branch
- Uncommitted changes
- Recent commits since last release tag
- Whether v2.3-library branch has commits that should be cherry-picked (or vice versa)

### 1.2 Determine what's being released

```bash
# Find the last release tag
git tag --sort=-v:refname | grep '^v' | head -5
# Commits since last tag
LAST_TAG=$(git tag --sort=-v:refname | grep '^v' | head -1)
git log --oneline "$LAST_TAG"..HEAD
```

Present the commit list and classify:
- Bug fixes
- New features
- Refactors / internal changes
- librespot-spoton/ changes (triggers binary rebuild)

### 1.3 librespot status check

```bash
# Check if Rust sources changed since last tag
LAST_TAG=$(git tag --sort=-v:refname | grep '^v' | head -1)
git diff --name-only "$LAST_TAG" HEAD -- librespot-spoton/ | head -5
# Current binary version
grep '^version' librespot-spoton/Cargo.toml
```

Also check upstream:
```bash
gh api repos/librespot-org/librespot/commits/dev --jq '.sha[:8] + " " + .commit.message' 2>/dev/null | head -1
```

Report:
- Whether binaries will be rebuilt or reused
- Whether upstream librespot dev has moved significantly since last build
- Status of our IPv6 patch (still needed? upstreamed?)

### 1.4 Binary version assessment

The binary version (`librespot-spoton/Cargo.toml`) is independent of the plugin version. Only bump when `librespot-spoton/` has changes.

**Bump rules (propose to user):**
- **Patch** (e.g. 2.0.8 → 2.0.9): bug fix in our Rust code
- **Minor** (e.g. 2.0.8 → 2.1.0): new CLI flags, new features in the binary
- **Major** (e.g. 2.0.8 → 3.0.0): librespot upstream major update, breaking protocol changes

If no Rust changes: skip binary version bump, report "Binary stays at vX.Y.Z (no Rust changes)."

### 1.5 Cherry-pick assessment

If on `main` and `v2.3-library` exists:
```bash
# Commits on library not on main
git log --oneline main..v2.3-library | head -10
# Commits on main not on library
git log --oneline v2.3-library..main | head -10
```

Ask user: "Any commits need cherry-picking between branches?"

## Phase 2: Version Agreement

### 2.1 Propose version

Based on the changes:
- Patch bump (x.y.Z): bug fixes only
- Minor bump (x.Y.0): new features
- Present proposal with rationale

Use AskUserQuestion to confirm the version number. **Never proceed without explicit approval.**

### 2.2 Check for [Unreleased] section

```bash
grep -A 20 "## \[Unreleased\]" CHANGELOG.md
```

If there are entries under [Unreleased], they should be moved to the new version section. If empty, ask user what to add.

## Phase 3: Prepare Release Commits

### 3.1 Update CHANGELOG.md

Move [Unreleased] entries to new version section with today's date:
```
## [X.Y.Z] - YYYY-MM-DD
```

If there are no [Unreleased] entries, draft the section from the commit log and present for approval.

### 3.2 Bump version in install.xml

Update line 19: `<version>X.Y.Z</version>`

### 3.3 Bump version in repo.xml (version only — SHA comes later)

Update the `version="X.Y.Z"` attribute. Leave sha as-is for now (will be updated after CI).

### 3.4 Run Perl tests (gate)

```bash
prove t/
```

All tests must pass before proceeding. If a test fails:
1. Fix the test (most likely a missing stub for newly-required modules)
2. Commit the test fix
3. Re-run `prove t/` to confirm

Common failure: adding a `require` for a module in a code path exercised by tests — the test needs a stub for the new dependency.

### 3.5 Commit the version bump

```bash
git add CHANGELOG.md Plugins/SpotOn/install.xml repo.xml
git commit -m "chore: bump version to vX.Y.Z"
```

### 3.6 Local test checkpoint

Ask user: "Have you tested this locally on your dev machine? The release should be verified before tagging."

Options:
- "Ja, getestet" → proceed
- "Nein, muss noch testen" → pause, give instructions on what to test
- "Überspringe für dieses Release" → proceed with warning

## Phase 4: Tag and CI Build

### 4.1 Push commits to main

```bash
git push origin main
```

Ask for approval first.

### 4.2 Create and push tag

Present the exact command:
```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

**Wait for explicit approval before executing.**

### 4.3 Monitor CI

```bash
gh run list --repo stiefenm/spoton --limit 3 --json status,conclusion,name,headBranch,createdAt \
  --jq '.[] | "\(.name)\t\(.status)\t\(.conclusion // "running")\t\(.headBranch)\t\(.createdAt)"'
```

Check if the build was triggered:
```bash
gh run list --repo stiefenm/spoton --workflow=build-librespot.yml --limit 1 \
  --json status,conclusion,databaseId \
  --jq '.[0] | "Run #\(.databaseId): \(.status) (\(.conclusion // "in progress"))"'
```

Report:
- Build triggered? (should show "in_progress" or "completed")
- Binary rebuild or reuse? (check detect-changes job output)
- Any failures?

If build is in progress, inform user and wait. Check again:
```bash
gh run view <RUN_ID> --repo stiefenm/spoton --json status,conclusion,jobs \
  --jq '{status: .status, conclusion: .conclusion, jobs: [.jobs[] | {name: .name, status: .status, conclusion: .conclusion}]}'
```

### 4.4 Verify release assets

Once CI completes:
```bash
gh release view vX.Y.Z --repo stiefenm/spoton --json assets \
  --jq '.assets[] | "\(.name)\t\(.size)"'
```

Expected assets (8 binaries + 1 zip + checksums):
- spoton-x86_64-linux
- spoton-aarch64-linux
- spoton-armhf-linux
- spoton-arm-linux
- spoton-i386-linux
- spoton-x86_64-win64.exe
- spoton-darwin
- SpotOn-vX.Y.Z.zip
- SHA256SUMS.txt

Report any missing assets.

## Phase 5: repo.xml SHA Update

### 5.1 Download fresh zip and compute SHA

**CRITICAL: Always download fresh from GitHub — never use a local or cached file.**

```bash
# Download fresh from GitHub release
gh release download vX.Y.Z --repo stiefenm/spoton -p 'SpotOn-vX.Y.Z.zip' -D /tmp/spoton-release-fresh/
sha1sum /tmp/spoton-release-fresh/SpotOn-vX.Y.Z.zip
rm -rf /tmp/spoton-release-fresh/
```

### 5.2 Update repo.xml

Present the change:
```xml
sha="<new-sha1>"
url="https://github.com/stiefenm/spoton/releases/download/vX.Y.Z/SpotOn-vX.Y.Z.zip"
version="X.Y.Z"
```

Get approval, then edit and commit:
```bash
git add repo.xml
git commit -m "chore: update repo.xml for vX.Y.Z"
git push origin main
```

### 5.3 Final verification

```bash
# Verify repo.xml is consistent
grep -E "version=|sha=|url=" repo.xml
```

Confirm all three values match the release.

## Phase 6: Documentation Review

### 6.1 README.md check

For each new feature or significant change:
- Is it mentioned in README.md?
- Are installation instructions still accurate?
- Does the "Features" section need updating?

### 6.2 TROUBLESHOOTING.md check

For each bug fix:
- Was this a common user issue?
- Should a troubleshooting entry be added/updated?
- Are workaround instructions still valid or now obsolete?

Present findings and propose edits. Get approval before making changes.

### 6.3 Commit docs if changed

```bash
git add README.md TROUBLESHOOTING.md
git commit -m "docs: update for vX.Y.Z release"
git push origin main
```

## Phase 7: Community Follow-up

### 7.1 Check affected issues

```bash
gh issue list --repo stiefenm/spoton --state open --json number,title,labels \
  --jq '.[] | "\(.number)\t\(.title)\t\(.labels | map(.name) | join(","))"'
```

For each open issue:
- Does this release fix or address it?
- Should we comment with "Fixed in vX.Y.Z — please update and confirm"?
- Should we add `waiting-user` label?

Draft comments for approval. **Never close issues without explicit user approval.**

### 7.2 Check forum topics

Review `forum-topics.json` for topics that this release addresses:
```bash
cat .github/scripts/forum-monitor/forum-topics.json | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k, v in d.get('resolved', {}).items():
    if v.get('status') in ('investigating', 'fix-shipped'):
        print(f'{k}: {v[\"status\"]} — {v.get(\"note\", \"\")[:80]}')
"
```

For topics with status `fix-shipped` or `investigating` that this release addresses:
- Draft a forum reply announcing the fix
- Write to `~/SynologyDrive/forum-reply-{post-nr}.txt`
- Update topic status in forum-topics.json

### 7.3 Present summary

```
## Release Summary — vX.Y.Z

### Artifacts
- [ ] Tag pushed: vX.Y.Z
- [ ] CI build: passed (binary rebuild / reuse)
- [ ] GitHub Release: created with N assets
- [ ] repo.xml: SHA updated and pushed

### Docs
- [ ] README.md: updated / no changes needed
- [ ] TROUBLESHOOTING.md: updated / no changes needed

### Community
- [ ] Issue #NN: commented / no action
- [ ] Forum post #NNN: reply drafted / no action

### Next Steps
- (anything remaining, e.g. "push repo.xml after verifying LMS picks up the update")
```

</process>

<tips>

## Common pitfalls

1. **SHA mismatch**: If you re-tag (delete + recreate), the zip changes → SHA is different. Always re-download after any tag manipulation.
2. **CI skips binary build**: If `librespot-spoton/` didn't change between tags, CI reuses old binaries. This is correct behavior — only flag if the user explicitly changed Rust code.
3. **repo.xml pushed before CI completes**: The zip doesn't exist yet → LMS shows download error. Always wait for CI green.
4. **CHANGELOG empty for version**: CI extracts release notes from CHANGELOG. If the section is missing, the release gets a generic "see CHANGELOG" message.
5. **Branch confusion**: Make sure you're on the right branch before tagging. `main` for hotfix releases, feature branch for milestone releases.
6. **Perl tests fail after tag**: If tests fail in CI after tagging, fix the test, delete the GH release (`gh release delete`), delete the remote tag (`git push origin :refs/tags/vX.Y.Z`), delete the local tag, push the fix, retag on HEAD, push tag. Never force-push the tag — delete and recreate cleanly.
7. **Test stubs**: When adding `require SomeModule` to a code path exercised by tests, the test file needs a corresponding `write_stub()` for that module. Most common miss: DaemonManager/Plugin.pm chain uses `main::DEBUGLOG` bareword.

## Version number semantics (SpotOn convention)

- **2.3.X** — current development line (post-v2.2 milestone)
- Patch bumps for bug fixes and minor improvements
- Feature additions within the v2.3 line also use patch bumps (rapid iteration phase)
- **v2.4.0** would be reserved for Library Integration completion (v2.3-library merge)

## librespot considerations

- We track `dev` branch, not releases — our binaries include fixes not yet in any librespot release
- The IPv6 patch in `librespot-discovery-patched/` may become unnecessary if PR #1724 merges upstream
- When updating the upstream pin (Cargo.lock refresh), it triggers a full binary rebuild
- `cargo update` in `librespot-spoton/` refreshes the lock file → counts as Rust source change for CI

## Quick release (Perl-only changes)

If only Perl files changed (no Rust):
1. CI will detect no changes in `librespot-spoton/` 
2. It downloads binaries from the previous release
3. Assembles new zip with old binaries + new Perl code
4. Total CI time: ~2 minutes instead of ~15 minutes

## Forum reply format (BBCode)

```
@username The fix for [issue description] is included in [B]vX.Y.Z[/B], now available via LMS plugin updates.

[URL=https://github.com/stiefenm/spoton/issues/NNN]GitHub #NNN[/URL]

To update: Settings → Manage Plugins → Check for updates → Restart LMS.
```

</tips>

# Automated Marketplace Release on Merge to Main — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every push to `main` with release-worthy commits automatically tags, moves a floating major-version tag, and creates a GitHub Release — so it appears on the Marketplace with no manual step, once the action has been published to the Marketplace one time (a manual, out-of-scope, one-time step).

**Architecture:** A new `.github/workflows/release.yml` runs on every push to `main`. It classifies commits since the last real (major ≥ 1) semver tag using Conventional Commits, computes the next version, tags it, force-moves the `vX` major tag, and runs `gh release create --generate-notes`. `README.md` is updated to document the new versioning scheme and point usage examples at the moving `@v1` tag.

**Tech Stack:** GitHub Actions workflow YAML, bash (`shell: bash`, GitHub-hosted `ubuntu-latest` runner), `git`, the pre-installed `gh` CLI. No new third-party Action dependencies.

## Global Constraints

- No tag matching `^v[1-9][0-9]*\.[0-9]+\.[0-9]+$` exists yet (confirmed: existing tags are `v0.0.1`–`v0.0.31`, `v0.1`, none of which match). The first push to `main` after this workflow lands MUST create `v1.0.0` unconditionally, regardless of commit content. All legacy tags are left untouched and ignored by all future runs.
- Steady-state bump classification (after `v1.0.0` exists): `feat!:`/`fix!:`/`BREAKING CHANGE:` → major, `feat:` → minor, `fix:` → patch, anything else → no release created (workflow run succeeds but does nothing further).
- The moving major tag (`vX`) is force-moved to point at the same commit as every new `vX.Y.Z` tag, per the `actions/checkout@v4`-style convention.
- No new third-party GitHub Action is added as a dependency — only `actions/checkout@v4` (already used elsewhere in this repo) plus `git`/`gh` directly.
- `permissions: contents: write` is scoped to the job; the job is guarded with `if: github.repository == 'sanderstad/FlywayCLIInstaller'` so forks don't tag their own copies.
- `concurrency: { group: release, cancel-in-progress: false }` at the workflow level, to serialize runs on rapid successive pushes.
- No test framework exists in this repo. Verification is a standalone bash test harness that runs the exact classification/version-arithmetic logic (copy-pasted verbatim from the workflow body, only the `${{ steps.*.outputs.* }}` GitHub Actions expressions replaced with plain shell variables since those expressions aren't valid outside a real Actions run) against a scratch git repo with fabricated tags/commits, plus a YAML validity check on the workflow file itself.

---

### Task 1: Add `.github/workflows/release.yml`

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:** None (standalone workflow, no other file depends on its internals).

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/release.yml` with this exact content:

```yaml
name: Release

on:
  push:
    branches: [main]

permissions:
  contents: write

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  release:
    if: github.repository == 'sanderstad/FlywayCLIInstaller'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Determine version bump
        id: bump
        shell: bash
        run: |
          LAST_TAG=$(git tag -l | grep -E '^v[1-9][0-9]*\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)

          if [ -z "$LAST_TAG" ]; then
            echo "bootstrap=true" >> "$GITHUB_OUTPUT"
            echo "bump=major" >> "$GITHUB_OUTPUT"
            echo "last_tag=none" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          COMMITS=$(git log "${LAST_TAG}..HEAD" --pretty=format:'%s%n%b')

          BUMP="none"
          if echo "$COMMITS" | grep -qE '^(feat|fix)(\([^)]+\))?!:|BREAKING CHANGE:'; then
            BUMP="major"
          elif echo "$COMMITS" | grep -qE '^feat(\([^)]+\))?:'; then
            BUMP="minor"
          elif echo "$COMMITS" | grep -qE '^fix(\([^)]+\))?:'; then
            BUMP="patch"
          fi

          echo "bootstrap=false" >> "$GITHUB_OUTPUT"
          echo "bump=$BUMP" >> "$GITHUB_OUTPUT"
          echo "last_tag=$LAST_TAG" >> "$GITHUB_OUTPUT"

      - name: Compute next version
        id: version
        if: steps.bump.outputs.bump != 'none'
        shell: bash
        run: |
          if [ "${{ steps.bump.outputs.bootstrap }}" = "true" ]; then
            echo "new_version=1.0.0" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          LAST_TAG="${{ steps.bump.outputs.last_tag }}"
          BUMP="${{ steps.bump.outputs.bump }}"
          VERSION="${LAST_TAG#v}"
          MAJOR=$(echo "$VERSION" | cut -d. -f1)
          MINOR=$(echo "$VERSION" | cut -d. -f2)
          PATCH=$(echo "$VERSION" | cut -d. -f3)

          case "$BUMP" in
            major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
            minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
            patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
          esac

          echo "new_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"

      - name: Create tags and release
        if: steps.bump.outputs.bump != 'none'
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          NEW_VERSION="${{ steps.version.outputs.new_version }}"
          NEW_TAG="v$NEW_VERSION"
          MAJOR_TAG="v$(echo "$NEW_VERSION" | cut -d. -f1)"

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

          git tag "$NEW_TAG"
          git push origin "$NEW_TAG"

          git tag -f "$MAJOR_TAG"
          git push origin "$MAJOR_TAG" --force

          gh release create "$NEW_TAG" --title "$NEW_TAG" --generate-notes
```

- [ ] **Step 2: Verify the workflow YAML is syntactically valid**

Run (this repo already confirmed the `powershell-yaml` PowerShell module is available in this environment — use it; if it's not installed here, install it first with `Install-Module -Name powershell-yaml -Scope CurrentUser -Force -Repository PSGallery`):

```powershell
pwsh -NoProfile -Command "Import-Module powershell-yaml; $null = ConvertFrom-Yaml (Get-Content -Raw '.github/workflows/release.yml'); 'OK'"
```

Expected: `OK`

- [ ] **Step 3: Build and run the standalone bump/version-classification test harness**

This tests the exact bash logic from Step 1's "Determine version bump" and "Compute next version" step bodies — copy-pasted verbatim, with only the `${{ steps.bump.outputs.* }}` GitHub Actions expressions (not valid bash outside a real Actions run) replaced by plain shell variables (`$BOOTSTRAP`, `$LAST_TAG`, `$BUMP`) populated from the first function's output. Write this to a scratch file (e.g. in the OS temp dir, NOT committed to the repo) and run it:

```bash
cat > /tmp/test-release-logic.sh << 'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

determine_bump() {
  # Verbatim from release.yml "Determine version bump" step, minus the
  # $GITHUB_OUTPUT file writes (this prints "key=value" lines to stdout
  # instead, which the caller captures).
  LAST_TAG=$(git tag -l | grep -E '^v[1-9][0-9]*\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)

  if [ -z "$LAST_TAG" ]; then
    echo "bootstrap=true"
    echo "bump=major"
    echo "last_tag=none"
    return 0
  fi

  COMMITS=$(git log "${LAST_TAG}..HEAD" --pretty=format:'%s%n%b')

  BUMP="none"
  if echo "$COMMITS" | grep -qE '^(feat|fix)(\([^)]+\))?!:|BREAKING CHANGE:'; then
    BUMP="major"
  elif echo "$COMMITS" | grep -qE '^feat(\([^)]+\))?:'; then
    BUMP="minor"
  elif echo "$COMMITS" | grep -qE '^fix(\([^)]+\))?:'; then
    BUMP="patch"
  fi

  echo "bootstrap=false"
  echo "bump=$BUMP"
  echo "last_tag=$LAST_TAG"
}

compute_version() {
  # Verbatim from release.yml "Compute next version" step, with
  # ${{ steps.bump.outputs.bootstrap/last_tag/bump }} replaced by
  # $BOOTSTRAP / $LAST_TAG / $BUMP (set by the caller from determine_bump's
  # output before calling this function).
  if [ "$BOOTSTRAP" = "true" ]; then
    echo "new_version=1.0.0"
    return 0
  fi

  VERSION="${LAST_TAG#v}"
  MAJOR=$(echo "$VERSION" | cut -d. -f1)
  MINOR=$(echo "$VERSION" | cut -d. -f2)
  PATCH=$(echo "$VERSION" | cut -d. -f3)

  case "$BUMP" in
    major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
    minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  esac

  echo "new_version=$NEW_VERSION"
}

run_scenario() {
  local name="$1"
  echo "=== $name ==="
  eval "$(determine_bump | sed 's/^bootstrap=/BOOTSTRAP=/; s/^bump=/BUMP=/; s/^last_tag=/LAST_TAG=/')"
  echo "  bootstrap=$BOOTSTRAP bump=$BUMP last_tag=$LAST_TAG"
  if [ "$BUMP" != "none" ]; then
    RESULT=$(compute_version)
    echo "  $RESULT"
  else
    echo "  (no release)"
  fi
}

TESTDIR=$(mktemp -d)
cd "$TESTDIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test"

# Scenario 1: no v1+ tag at all (true bootstrap) -> expect bootstrap=true, bump=major, new_version=1.0.0
git commit -q --allow-empty -m "chore: initial commit"
run_scenario "1: clean bootstrap, no tags at all"

# Scenario 2: legacy non-semver tags present but no v1+ tag -> still bootstrap -> new_version=1.0.0
git tag v0.0.31
git tag v0.1
run_scenario "2: legacy v0.0.x/v0.1 tags present, still bootstrap"

# From here, simulate v1.0.0 having been created by a prior run.
git tag v1.0.0

# Scenario 3: feat: commit since v1.0.0 -> expect bump=minor, new_version=1.1.0
git commit -q --allow-empty -m "feat: add widget support"
run_scenario "3: feat commit -> minor bump"

git tag v1.1.0

# Scenario 4: fix: commit since v1.1.0 -> expect bump=patch, new_version=1.1.1
git commit -q --allow-empty -m "fix: correct widget alignment"
run_scenario "4: fix commit -> patch bump"

git tag v1.1.1

# Scenario 5: feat!: breaking commit since v1.1.1 -> expect bump=major, new_version=2.0.0
git commit -q --allow-empty -m "feat!: remove deprecated widget API"
run_scenario "5: breaking feat commit -> major bump"

git tag v2.0.0

# Scenario 6: only chore: commit since v2.0.0 -> expect bump=none, no release
git commit -q --allow-empty -m "chore: tidy up comments"
run_scenario "6: chore-only commit -> no release"

rm -rf "$TESTDIR"
HARNESS
bash /tmp/test-release-logic.sh
rm /tmp/test-release-logic.sh
```

Expected output (six scenarios, in order):
```
=== 1: clean bootstrap, no tags at all ===
  bootstrap=true bump=major last_tag=none
  new_version=1.0.0
=== 2: legacy v0.0.x/v0.1 tags present, still bootstrap ===
  bootstrap=true bump=major last_tag=none
  new_version=1.0.0
=== 3: feat commit -> minor bump ===
  bootstrap=false bump=minor last_tag=v1.0.0
  new_version=1.1.0
=== 4: fix commit -> patch bump ===
  bootstrap=false bump=patch last_tag=v1.1.0
  new_version=1.1.1
=== 5: breaking feat commit -> major bump ===
  bootstrap=false bump=major last_tag=v1.1.1
  new_version=2.0.0
=== 6: chore-only commit -> no release ===
  bootstrap=false bump=none last_tag=v2.0.0
  (no release)
```

If any scenario's actual output doesn't match, the workflow's bash logic has a bug — fix `.github/workflows/release.yml` (and re-sync the test harness's copies of the two step bodies to match, since they must stay verbatim copies) before proceeding.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add automated release workflow for merges to main"
```

---

### Task 2: Update README.md for the new versioning scheme

**Files:**
- Modify: `README.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Update both usage examples from `@v0.1` to `@v1`**

Current (README.md, "Usage" section):
```yaml
- name: Install Flyway CLI
  uses: sanderstad/FlywayCLIInstaller@v0.1
  with:
    version: 'latest' # or specify a version, e.g. '11.8.2'
```

Replace with:
```yaml
- name: Install Flyway CLI
  uses: sanderstad/FlywayCLIInstaller@v1
  with:
    version: 'latest' # or specify a version, e.g. '11.8.2'
```

Current (README.md, "Example Workflow" section):
```yaml
jobs:
  flyway-setup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Flyway CLI
        uses: sanderstad/FlywayCLIInstaller@v0.1
        with:
          version: 'latest'
```

Replace with:
```yaml
jobs:
  flyway-setup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Flyway CLI
        uses: sanderstad/FlywayCLIInstaller@v1
        with:
          version: 'latest'
```

- [ ] **Step 2: Add a "Releases" section**

Insert a new section after "How it works" (before "## Notes"). Current text immediately before the insertion point:

```markdown
Network calls to Red Gate's download server (both the version-metadata lookup and the archive download) are retried up to `retry-count` times, `retry-delay-seconds` apart, before the action fails. This helps with intermittent `403` responses from the server.

## Notes
```

Replace with:

```markdown
Network calls to Red Gate's download server (both the version-metadata lookup and the archive download) are retried up to `retry-count` times, `retry-delay-seconds` apart, before the action fails. This helps with intermittent `403` responses from the server.

## Releases

Every push to `main` is automatically versioned and released — no manual tagging. The version bump is determined from commit messages since the last release, following [Conventional Commits](https://www.conventionalcommits.org/):

- `fix: ...` → patch release (e.g. `v1.0.0` → `v1.0.1`)
- `feat: ...` → minor release (e.g. `v1.0.1` → `v1.1.0`)
- `feat!: ...`, `fix!: ...`, or a `BREAKING CHANGE:` footer → major release (e.g. `v1.1.0` → `v2.0.0`)
- Anything else (`chore:`, `docs:`, `ci:`, etc.) does not trigger a release on its own

This repo merges pull requests via squash merge, so the PR title becomes the commit message that gets classified — use a Conventional Commits prefix in your PR title.

Each release also moves a floating major-version tag (e.g. `v1`) to point at the latest release in that major line, so `uses: sanderstad/FlywayCLIInstaller@v1` always tracks the newest compatible release. Pin an exact `vX.Y.Z` tag instead if you need a fully immutable reference.

## Notes
```

- [ ] **Step 3: Verify the file reads cleanly and both `@v1` replacements landed**

```bash
grep -n '@v0.1' README.md; echo "exit code: $?"
grep -n '@v1' README.md
```

Expected: the first command finds no matches (exit code `1`, meaning `@v0.1` is fully gone); the second command shows both usage examples now using `@v1`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Document automated release process and update usage examples to @v1"
```

---

## Final Verification

- [ ] Re-read the full `.github/workflows/release.yml` end to end and confirm YAML indentation is consistent (no tabs, consistent step-list indentation) — a broken indent fails the whole workflow at parse time.
- [ ] Confirm `git log --oneline -3` shows the two new commits (workflow + README) on top of the design/plan doc commits, on branch `add-release-automation`.
- [ ] Tell the user explicitly, in the final report: after this branch merges and the next push to `main` creates the bootstrap `v1.0.0` release, they must manually visit that release on github.com, click "Edit release," and check "Publish this Action to the GitHub Marketplace" (choosing a category) — this is a one-time step with no API equivalent, not automated by this plan.

# Automated Marketplace Release on Merge to Main — Design

## Problem

Releases to the GitHub Marketplace currently happen manually: someone has to
create a git tag and a GitHub Release by hand after merging changes into
`main`. The repo's existing tag history reflects this — a long run of
`v0.0.1` through `v0.0.31`, then a jump straight to `v0.1`, with no
consistent semver and no moving major-version tag for consumers to pin to.

## Goal

Every push to `main` that contains release-worthy changes automatically:

1. Computes the next version number from Conventional Commit messages since
   the last real release.
2. Creates the `vX.Y.Z` tag.
3. Force-moves a floating `vX` major tag to the same commit (the
   `actions/checkout@v4`-style convention), so consumers can pin
   `uses: sanderstad/FlywayCLIInstaller@v1` and get updates automatically.
4. Creates a GitHub Release for `vX.Y.Z` with auto-generated release notes.

Once a release has been published to the Marketplace one time (a manual,
one-time step — see Non-goals), every release this workflow creates from
then on appears in the Marketplace automatically, with no further manual
steps.

## Non-goals

- **First-time Marketplace publish.** GitHub has no public API for the
  one-time "Publish this Action to the GitHub Marketplace" checkbox +
  category selection on a release. This remains a manual, one-time step
  the repo owner performs after the first `v1.0.0` release is created.
  Documented as a follow-up action item, not built here.
- **No third-party tag/release Marketplace action.** The workflow uses only
  `git` and the pre-installed `gh` CLI on GitHub-hosted runners — no new
  external Action dependency. This repo currently depends on nothing but
  `actions/checkout`; adding a third-party action with `contents: write`
  (effectively push access) for something this small isn't worth the
  supply-chain surface, especially right after a script-injection finding
  in the same repo's action.yml.
- **No release-PR / bot-maintained changelog PR pattern** (e.g. Release
  Please). The user wants a release to happen automatically when they
  merge — not to merge a feature PR and then also merge a second,
  bot-generated release PR.
- **No per-file changelog generation.** Release notes come entirely from
  `gh release create --generate-notes`, GitHub's built-in PR-based
  changelog. Nothing hand-maintained.

## Versioning scheme

### Bootstrap (one-time)

None of the existing tags (`v0.0.1`–`v0.0.31`, `v0.1`) are valid 3-part
semver with major ≥ 1. The workflow treats the absence of any tag matching
`^v[1-9][0-9]*\.[0-9]+\.[0-9]+$` as a signal that this is the first run
under the new scheme: the next push to `main` creates **`v1.0.0`**
unconditionally, regardless of what the pushed commits' messages say. All
legacy `v0.0.x`/`v0.1` tags are left in place, untouched, and ignored by
every future run of this workflow.

### Steady state (after `v1.0.0` exists)

On every subsequent push to `main`:

1. Find `LAST_TAG` = the highest tag matching `^v[1-9][0-9]*\.[0-9]+\.[0-9]+$`.
2. Collect the subject line of every commit in `LAST_TAG..HEAD`.
3. Classify using Conventional Commits, most severe match wins:
   - Any commit subject matching `^(feat|fix)(\(.+\))?!:` or containing a
     `BREAKING CHANGE:` footer → **major** bump.
   - Any commit subject matching `^feat(\(.+\))?:` → **minor** bump.
   - Any commit subject matching `^fix(\(.+\))?:` → **patch** bump.
   - None of the above (only `chore:`, `docs:`, `ci:`, unprefixed commits,
     etc.) → **no release** is created for this push. The workflow run
     still succeeds; it just does nothing after the classification step.
4. Compute the new version from `LAST_TAG` and the bump size, create the
   tag, move the major tag, create the release.

This matches standard Angular-convention release automation: only
`feat`/`fix`/breaking changes trigger a release; everything else is release
history that rides along in the next real release's notes.

## Workflow implementation

New file: `.github/workflows/release.yml`

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

Notes on specific lines:
- `fetch-depth: 0` — the default shallow checkout has no tags and no
  history to diff against; the whole scheme depends on full tag/commit
  history being present.
- `if: github.repository == 'sanderstad/FlywayCLIInstaller'` — prevents a
  fork from tagging/releasing its own copy on every push to its `main`.
- Bootstrap short-circuits to `v1.0.0` and skips commit classification
  entirely — this is the one-time exception described above.
- `git tag -f "$MAJOR_TAG"` + `push --force` moves the floating major tag;
  this is the standard, widely-used Marketplace Action convention (e.g.
  `actions/checkout@v4` works exactly this way) — the trade-off (a moving
  ref instead of an immutable one) is accepted deliberately for that
  compatibility.
- `gh release create --generate-notes` needs no extra permissions beyond
  `contents: write`, already granted at the job level.
- `concurrency: { group: release, cancel-in-progress: false }` at the
  workflow level serializes runs so two rapid pushes to `main` can't both
  compute the same next version and race on creating the same tag; the
  second run queues and re-reads tag state after the first completes.

## README changes

- Update both usage examples from `uses: sanderstad/FlywayCLIInstaller@v0.1`
  to `uses: sanderstad/FlywayCLIInstaller@v1`.
- Add a short "Releases" section under "How it works" explaining: pushes to
  `main` are automatically versioned from Conventional Commit messages
  (`feat:`, `fix:`, `feat!:`/`BREAKING CHANGE:`) and released; contributors
  should use these prefixes in commit/PR titles (this repo squash-merges,
  so the PR title becomes the commit message that gets classified).

## Manual follow-up (not part of this implementation)

After the first `v1.0.0` release is created by this workflow, the repo
owner needs to go to that release on github.com, click "Edit release," and
check "Publish this Action to the GitHub Marketplace," picking a category.
This is a one-time step with no API equivalent. This design doc and the
final report to the user will call this out explicitly; it is not
automated by any task in the implementation plan.

## Testing

No test framework exists in this repo. Verification is:
- Manual `bash -n` / shellcheck-style syntax review of the embedded bash
  (or actually running the classification logic against a scratch git repo
  with fabricated tags and commits to confirm bump-detection and version
  arithmetic behave as designed, including the bootstrap path).
- A YAML validity check on the new workflow file.
- Real end-to-end confirmation only happens on the next actual push to
  `main` after this merges — flagged clearly to the user, not claimed as
  verified here.

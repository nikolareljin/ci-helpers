# Composite Actions

These composite actions are intended for reuse inside your workflows.

Related docs:
- [Reusable workflows](workflows.md)
- [Examples](examples.md)

## semver-compare

Path: `.github/actions/semver-compare`

Purpose: Compare two semver strings and return `lt`, `eq`, or `gt`.

Inputs:
- `version_a` (required)
- `version_b` (required)

Outputs:
- `result` (`lt`, `eq`, or `gt`)

Example:

```yaml
- name: Compare versions
  id: semver
  uses: nikolareljin/ci-helpers/.github/actions/semver-compare@v0.1.0
  with:
    version_a: "1.2.3"
    version_b: "1.4.0"

- name: Use result
  run: echo "Result: ${{ steps.semver.outputs.result }}"
```

## check-release-tag

Path: `.github/actions/check-release-tag`

Purpose: Fail if a `release/X.Y.Z` (or `release/vX.Y.Z`) branch already has a tag.

Inputs:
- `release_branch` (optional, defaults to `GITHUB_HEAD_REF`/`GITHUB_REF_NAME`)
- `repo_dir` (optional, defaults to `GITHUB_WORKSPACE`)
- `fetch_tags` (optional, default `"true"`)

Outputs:
- `version` (parsed from the release branch, e.g. `1.2.3`)

Example:

```yaml
- name: Guard release tag
  id: release_guard
  uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@v0.1.0
  with:
    release_branch: ${{ github.head_ref }}
    fetch_tags: true

- name: Use version
  run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

Notes:
- The guard expects branch naming `release/X.Y.Z` or `release/vX.Y.Z`.

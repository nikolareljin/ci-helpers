Release Checklist
=================

This project is intended to be used as a submodule across other repos. These are the steps to publish a new version and integrate it downstream.

Versioning and releases
-----------------------
- Update VERSION with bump script (patch/minor/major):
  - `scripts/bump_version.sh patch`
  - `git add VERSION && git commit -m "chore(release): bump version"`
- Tag and push:
  - `scripts/tag_release.sh`
  - This creates tag `<version>` (no 'v' prefix) based on VERSION and pushes it
  - Then run `scripts/pin_production.sh <version>` to move `production` for this manual flow.
- GitHub Actions creates a release for pushed tag with auto-generated notes
- `production` branch is auto-moved to the new tag by release automation in the same workflow run that creates the tag on `main`.
- Manual fallback (or rollback) to a specific tag:
  - `scripts/pin_production.sh <version>`
  - If a rollback is needed, fast-forward `production` to a previous tag.

Downstream projects
-------------------
- Add as submodule in each project repo (example):
  - `git submodule add -b production git@github.com:nikolareljin/script-helpers.git inc/script-helpers`
  - Or pin a specific tag:
    - `git submodule add -b 0.1.0 git@github.com:nikolareljin/script-helpers.git inc/script-helpers`
- To bump submodule in downstream repos to a new version:
  - `cd inc/script-helpers && git fetch --tags && git checkout X.Y.Z && cd -`
  - `git add inc/script-helpers && git commit -m "chore: bump script-helpers to X.Y.Z"`

CI workflows
------------
- `.github/workflows/auto-tag-release.yml`: On merge of a `release/X.Y.Z` PR into `main`, reuses the shared ci-helpers workflows to detect the version, create the tag, create the GitHub Release, and move the `production` branch to it.
- `.github/workflows/release.yml`: On a manually-pushed tag `*.*.*` (fallback path), creates the GitHub Release via the shared ci-helpers `create-github-release` workflow.
- `.github/workflows/release-version-check.yml`: PR gate that enforces `VERSION` matches the `release/X.Y.Z` branch name.

Notes
-----
- Keep modules backward-compatible where possible; deprecate before removing
- Avoid breaking downstream by coordinating larger changes; use a minor or major bump accordingly

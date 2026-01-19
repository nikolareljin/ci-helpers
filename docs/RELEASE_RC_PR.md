# Release RC PR Workflow

This repo includes a repo-local workflow that opens a PR when a release candidate branch is created.

## Behavior
- Trigger: creation of branches matching `release/X.Y.Z` or `release/X.Y.Z-rc*`
- Action: opens a PR from the new branch to the default branch
- Default branch is detected via GitHub API (e.g., `main` or `master`)
- If a PR already exists for that head/base, it does nothing

## Workflow file
- `.github/workflows/release-rc-pr.yml`

## Example branches
- `release/1.2.3`
- `release/1.2.3-rc1`

## Notes
- This only runs on branch creation (not on push).
- This workflow is repository-local (not a reusable workflow).

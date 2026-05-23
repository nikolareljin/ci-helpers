# Release RC PR Workflow

`.github/workflows/release-rc-pr.yml` — opens a PR to the default branch
whenever a release candidate branch is created.  The workflow serves two roles:

| Role | Trigger |
|------|---------|
| **ci-helpers-internal** | `on: create` — auto-fires when a `release/*` branch is pushed to ci-helpers itself |
| **Caller reusable** | `workflow_call` — any repo can call it to get the same auto-PR behaviour |

---

## Required setup

The workflow needs permission to create pull requests.  GitHub provides two paths:

### Option A — Enable the repository setting (recommended)

**Settings → Actions → General → Workflow permissions →**
tick **"Allow GitHub Actions to create and approve pull requests"**.

This lets the built-in `GITHUB_TOKEN` create PRs.  No secrets required.

### Option B — Add a `GH_PAT` secret

If the repo setting above is disabled (e.g. org policy blocks it), add a
repository secret named **`GH_PAT`** containing either:
- a classic PAT with `repo` scope, or
- a fine-grained PAT with **Pull requests: Read and write** access.

The workflow uses `${{ secrets.GH_PAT || github.token }}` — it prefers the
PAT when present and falls back to `github.token` otherwise.

> **Security note:** store `GH_PAT` in the *caller* repo only, scoped to that
> repo.  ci-helpers never stores a cross-repo token.  The secret flows through
> GitHub's encrypted `workflow_call` secrets mechanism and is only visible
> inside the job that needs it.

---

## Using this as a reusable workflow (caller repos)

Add a small wrapper in your repo. The caller's `on: create` event provides
`github.ref_name` which the called workflow reads directly — no extra inputs
needed in the common case.

```yaml
# .github/workflows/release-pr.yml  (in your repo)
name: Open release PR

on:
  create:

jobs:
  open-pr:
    if: ${{ github.event.ref_type == 'branch' && startsWith(github.event.ref, 'release/') }}
    uses: nikolareljin/ci-helpers/.github/workflows/release-rc-pr.yml@production
    secrets: inherit          # passes GH_PAT if you set it; falls back to github.token
```

If your default branch is not `main`, pass the `base_branch` input:

```yaml
    uses: nikolareljin/ci-helpers/.github/workflows/release-rc-pr.yml@production
    with:
      base_branch: master
    secrets: inherit
```

### Why `secrets: inherit` is safe here

- The `GITHUB_TOKEN` the called workflow uses is scoped to **your repo only**.
  It cannot access ci-helpers or any other repo.
- `GH_PAT`, if present, is a fine-grained PAT you stored in your own repo,
  scoped to your repo.  Neither token gives ci-helpers any cross-repo access.
- This is the same model all other ci-helpers `workflow_call` workflows use.

---

## Inputs (workflow_call)

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `base_branch` | string | `main` | Branch the PR targets. Pass `master` or another name to override. For `on:create` the actual default branch is always read from the event payload. |

## Secrets (workflow_call)

| Secret | Required | Description |
|--------|----------|-------------|
| `GH_PAT` | no | PAT with `pull_requests: write`; falls back to `github.token` |

---

## Behaviour

- **Trigger (internal):** `on: create` event — fires once when a branch is
  first pushed, not on subsequent commits to that branch.
- **Trigger (callers):** `workflow_call` from a caller's `on: create` wrapper.
- **Filter:** only acts on branches matching `release/[v]X.Y.Z`,
  `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N`.
- **Idempotent:** if a PR already exists for that head/base pair, it does nothing.
- **Default branch detection:**
  - `workflow_call`: reads the `base_branch` input (default `main`).
  - `on:create`: reads `context.payload.repository.default_branch` from the
    event payload (no API call needed).

---

## Historical failure analysis

Every release branch from `0.6.3` through `0.9.3` had this workflow fail.
Two compounding bugs, fixed in `0.10.0`:

1. **Unnecessary `repos.get()` API call** — the original workflow called
   `github.rest.repos.get()` solely to read `default_branch`.  Under
   `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`, `actions/github-script` returned
   `401` for this call.  Fixed by reading `default_branch` from the event
   payload instead.

2. **Repo-level PR gate was disabled** — after fixing the 401, the actual
   `pulls.create()` call returned `403 GitHub Actions is not permitted to
   create or approve pull requests`.  Fixed by enabling **Option A** above
   (or providing `GH_PAT`).

---

## Example branches

| Branch | Triggers? |
|--------|-----------|
| `release/1.2.3` | yes |
| `release/v1.2.3` | yes |
| `release/1.2.3-rc1` | yes |
| `release/1.2.3-rc.1` | yes |
| `release/1.2.3-hotfix` | no — non-numeric suffix |
| `feature/1.2.3` | no — wrong prefix |

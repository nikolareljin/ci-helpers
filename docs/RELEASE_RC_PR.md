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

The PR targets the repository's default branch. To target a different branch, pass `base_branch` (any value other than `main` is used as given):

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
| `base_branch` | string | `main` | Branch the PR targets. Any value other than `main` is used as given. `main` -- also the default, so it cannot be told apart from passing nothing -- uses the repository's default branch from the event payload. |

## Secrets (workflow_call)

| Secret | Required | Description |
|--------|----------|-------------|
| `GH_PAT` | no | PAT with pull-request write access (classic: `repo` scope; fine-grained: Pull requests Read+write); falls back to `github.token` |

---

## Behaviour

- **Trigger (internal):** `on: create` event — fires once when a branch is
  first pushed, not on subsequent commits to that branch.
- **Trigger (callers):** `workflow_call` from a caller's wrapper -- `on: create`
  (filtered to `release/*` branches) or any other event, e.g. `on: push` to
  `release/*`.
- **Filter:** only acts on branches matching `release/[v]X.Y.Z`,
  `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N`.
- **Idempotent:** if a PR already exists for that head/base pair, it does nothing.
- **Default branch detection:**
  - `workflow_call` with a `base_branch` other than `main`: that branch.
  - Otherwise (`base_branch` is `main`, or ci-helpers' own `on: create`):
    `context.payload.repository.default_branch` from the event payload (no API
    call needed), then `main`.

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

---

## Before every full release: refresh the action pins

A full release (`X.Y.Z`, not an `-rcN`) must update the third-party action SHAs
first. Run it on the release branch, before cutting:

```bash
bash scripts/update_pinned_actions.sh          # rewrite stale pins
bash scripts/update_pinned_actions.sh --check  # must report 0 stale, 0 warnings
```

Why this is a release step and not left to the bots: Dependabot opens one pull
request per action and **moves the SHA without touching the version comment**.
Merging six of those leaves six pins reading `# v1.321.0 @ 2026-09-10` while
pointing at v1.324.0. `scripts/update_pinned_actions.sh` and the security audit
both read those comments, so the repository ends up reporting a version it does
not ship.

Without this step, a consumer pinned to `@production` gets an action version
nobody recorded.

Two things to check by hand when a Dependabot pin looks wrong:

- `git/ref/tags/<tag>` returns the **tag object** for an annotated tag, not the
  commit. Dereference it before comparing SHAs, or `github/codeql-action` will
  look like a mismatch when it is correct.
- The comment format is `# vX.Y.Z @ YYYY-MM-DD`, with the date of the bump, not
  the date of the upstream release.

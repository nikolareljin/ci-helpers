# Private Repo CI Strategy

Actions minutes on a private repository are billed. This document is about
spending as few of them as possible without giving up the checks.

## Layer 0 — local

```
Layer 0  LOCAL   pre-commit  (.env guard, version check)              < 1s    $0
                 pre-push    → stack-specific quick tests             ~10–60s $0
                 ci_*.sh     (lint, tests, build, scan)                minutes $0
```

`script-helpers` ships stack-specific `ci_*.sh` commands for running the same
classes of checks locally. It also includes a blocking pre-push hook that
detects a supported stack at the repository root and runs its quick test
command. Install the hooks with:

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh
```

Run every applicable `ci_*.sh` command explicitly in multi-stack repositories;
the hook does not discover nested projects or combine multiple stacks.

Every `ci_*.sh` runner in `script-helpers` refuses to run when `CI=true`. They
are deliberately local tools; the library was built for this model.

## How much CI to keep

Pick a tier and stay in it. The right one depends on how many people push.

### Release-only — one contributor, private repo

**The recommended default for a single-maintainer private repo.**
`.github/workflows/` holds tagging and release, and nothing else:

| Workflow | Trigger | Typical cost |
|---|---|---|
| `auto-tag-release.yml` | `push` to `main` | ~0.2 min |
| `release-tag-gate.yml` | `pull_request` from `release/*` | ~0.2 min |
| `release.yml` | `push` of a version tag | per release, not per push |

Everything else runs locally through the applicable `ci_*.sh` commands, with
quick tests gated by a **blocking** pre-push hook. With the PR gate gone that
hook is the only automatic gate left, so it must fail the push rather than warn;
`git push --no-verify` stays as the escape hatch.

The trade is explicit: a local gate is a convention, not a control. It can be
skipped, and nothing verifies a *contributor's* change before merge. That costs
nothing at one contributor per repo, and it is the first thing that breaks when
that changes.

One exception is worth keeping: a **weekly scheduled secret and vulnerability
sweep**. Secret scanning is worth more on a server than locally precisely
because it catches what a developer forgot to run, and a `schedule:` sweep is a
few minutes of Actions per month.

### Three layers — two or more contributors

```
Layer 0  LOCAL      pre-commit + pre-push → quick tests           $0
Layer 1  PR GATE    pr-gate.yml (install once → lint → test)      ~2–3 min, 1 job
Layer 2  MAIN GATE  ci.yml (full lint + test + build, post-merge) ~5 min, 1–3 jobs
```

Restore this the moment a repo gains a second regular contributor. Layer 0
catches the author's own mistakes; Layers 1 and 2 exist to catch everyone else's.

### Rules that apply in either tier

- `ci.yml` — **NEVER** has a `pull_request` trigger. `push: branches: [main, master]`
  only. Listing both for the same branches runs the full workflow **twice per
  merged PR**, which is the single most common waste in this namespace.
- `pr-gate.yml` — `pull_request` only; add `paths-ignore: ["docs/**","*.md"]`.
  Without it a README typo pays for a full build.
- Use `install_command` so dependencies are installed once; `lint_command` and
  `test_command` reuse them.
- Never run a `macos-*` or `windows-*` job on push or pull request. macOS bills
  at a **10× minute multiplier** and Windows at **2×**. Put them behind a manual
  `workflow_dispatch` input, the way `flutter-release.yml` gates its App Store
  leg behind `deploy_app_store`.
- Never use an OS matrix on a private repo for anything but a tagged release.
  A serialized three-way matrix costs the sum of its legs in wall-clock and the
  weighted sum in minutes.

### What the reusable workflows now enforce

As of 0.19.0 the cost controls live in the workflows rather than only in this
document:

| Workflow | `timeout_minutes` default | `concurrency` |
|---|---|---|
| `ci.yml` | 20 | cancel-in-progress |
| `pr-gate.yml` | 20 | cancel-in-progress |
| `release-build.yml` | 30 | — |
| `kotlin.yml`, `java-gradle.yml` | 20 (passed through to `ci.yml`) | via `ci.yml` |
| `flutter-release.yml` | 60 | — |

Before this, `timeout-minutes` appeared **nowhere** across the reusable
workflows: a hung job billed until GitHub's six-hour cap. Every value is an
optional input, so callers that pass nothing keep working.

---

## Quick Setup

### Step 1 — Install local hooks (once per clone)

```bash
# If script-helpers is vendored as a submodule at scripts/script-helpers/
bash scripts/script-helpers/scripts/setup-hooks.sh

# Or, if script-helpers is at a custom path
git config core.hooksPath .githooks
```

### Step 2 — Standard workflow pair

**`.github/workflows/ci.yml`** (post-merge, main/master only)

```yaml
name: CI
on:
  push:
    branches: [main, master]

jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/<stack>.yml@production
    with:
      # ... stack-specific inputs
```

**`.github/workflows/pr-gate.yml`** (every PR push)

```yaml
name: PR Gate
on:
  pull_request:
    paths-ignore:
      - "docs/**"
      - "*.md"
concurrency:
  group: pr-gate-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pr-gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@production
    with:
      # ... stack-specific inputs (see per-stack examples below)
```

---

## Per-Stack Examples

### Node / TypeScript

```yaml
# pr-gate.yml
with:
  node_version: "22"
  install_command: "npm ci"
  lint_command: "npm run build"       # type-check / compile
  test_command: "npm test"
  build_command: ""

# ci.yml (post-merge, full build)
with:
  node_version: "22"
  lint_command: "npm ci && npm run build"
  test_command: "npm test"
  build_command: "npm run build"
```

### Python

```yaml
# pr-gate.yml
with:
  python_version: "3.13"
  install_command: "pip install -e '.[dev]'"
  lint_command: "ruff check ."
  test_command: "pytest -q"
  build_command: ""

# ci.yml
with:
  python_version: "3.13"
  lint_command: "pip install -e '.[dev]' && ruff check . && mypy ."
  test_command: "pytest -q"
  build_command: "python -m build"
```

### Go

```yaml
with:
  go_version: "1.24"
  lint_command: "go vet ./..."
  test_command: "go test ./..."
  build_command: ""
```

No `install_command` needed — `go` fetches modules automatically.

### Rust

```yaml
with:
  rust_toolchain: "stable"
  rust_components: "clippy"
  lint_command: "cargo check && cargo clippy -- -D warnings"
  test_command: "cargo test"
  build_command: ""
```

### Flutter

```yaml
with:
  flutter_channel: "stable"
  install_command: "flutter pub get"
  lint_command: "flutter analyze"
  test_command: "flutter test"
  build_command: ""
```

### Java / Gradle

```yaml
with:
  java_version: "17"
  lint_command: "./gradlew lint"
  test_command: "./gradlew test"
  build_command: ""
```

### Android (Gradle)

Android task names are variant-qualified, and the generic ones do not exist in an
Android project — `./gradlew test` runs no unit tests where
`testDebugUnitTest` does.

```yaml
with:
  java_version: "17"
  lint_command: "./gradlew lintDebug"
  test_command: "./gradlew testDebugUnitTest"
  build_command: ""          # assembleDebug is post-merge work, not a PR gate
```

On a release-only private repo, run these tasks locally with the vendored Gradle
runner. Android task names must be supplied explicitly:

```bash
bash scripts/script-helpers/scripts/ci_gradle.sh \
  --workdir android \
  --build-task assembleDebug \
  --test-task testDebugUnitTest \
  --lint-task lintDebug \
  --skip-detekt
```

### PHP

```yaml
with:
  php_version: "8.3"
  install_command: "composer install --no-interaction"
  lint_command: "vendor/bin/phpstan analyse"
  test_command: "vendor/bin/phpunit"
  build_command: ""
```

---

## Finding the double-trigger

A survey of consuming repositories found nine running 2× CI per push — a
`pull_request` trigger in `ci.yml` **and** a `pr-gate.yml` on the same branches.
The affected stacks were Node, Go, Python, Rust, Java and Flutter, so this is not
a property of any one toolchain; it is what happens when `ci.yml` is copied from
a template that has both triggers.

Check a repo with:

```bash
gh api "repos/OWNER/REPO/contents/.github/workflows/ci.yml" \
  --jq '.content' | base64 -d | grep -A3 '^on:'
```

Or measure it after the fact — a workflow that runs twice per merge shows up
immediately in the run history:

```bash
gh api "/repos/OWNER/REPO/actions/runs?per_page=100" --jq '
  [.workflow_runs[] | {wf:.name, min: (((.updated_at|fromdate) - (.run_started_at|fromdate))/60)}]
  | group_by(.wf) | map({wf:.[0].wf, runs:length, total_min:((map(.min)|add)|round)})
  | sort_by(-.total_min) | .[]'
```

**Pattern** — edit `ci.yml` in each affected repo:

```yaml
# Before
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

# After
on:
  push:
    branches: [main, master]
```

---

## Local Testing Scripts (script-helpers)

These are available after vendoring `script-helpers` as a submodule under `scripts/script-helpers/`:

| Script | What it runs |
|--------|-------------|
| `scripts/script-helpers/scripts/local_test_node.sh` | `npm ci` → `npm test`; `--quick` skips install |
| `scripts/script-helpers/scripts/local_test_python.sh` | pip install → `pytest`; `--quick` skips install |
| `scripts/script-helpers/scripts/local_test_go.sh` | `go vet` → `go test ./...`; `--quick` skips vet |
| `scripts/script-helpers/scripts/local_test_rust.sh` | `cargo check` → `cargo clippy` → `cargo test` |
| `scripts/script-helpers/scripts/local_test_flutter.sh` | `flutter pub get` → `flutter analyze` → `flutter test` |

The pre-push hook (`scripts/script-helpers/scripts/git-hooks/pre-push`) auto-detects the stack and calls the appropriate runner, so tests run on every `git push` without any per-repo configuration. Enable it via:

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh
```

# Private Repo CI Strategy

## The 3-Layer Model

```
Layer 1  LOCAL      pre-commit  (.env guard, version check)         < 1s   $0
                    pre-push    (language-specific tests)           ~5–15s  $0
Layer 2  PR GATE    pr-gate.yml (install once → lint → test)       ~2–3min 1 job
Layer 3  MAIN GATE  ci.yml      (full lint + test + build, post-merge) ~5min 1–3 jobs
```

### Rules

- `ci.yml` — **NEVER** has `pull_request` trigger. `push: branches: [main, master]` only.
- `pr-gate.yml` — `pull_request` only; add `paths-ignore: ["docs/**","*.md"]` and `cancel-in-progress: true`.
- Use `install_command` so dependencies are installed once; `lint_command`/`test_command` reuse them.
- Local pre-push runs the same tests as the PR gate — most failures are caught before the push.

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
  python_version: "3.12"
  install_command: "pip install -e '.[dev]'"
  lint_command: "ruff check ."
  test_command: "pytest -q"
  build_command: ""

# ci.yml
with:
  python_version: "3.12"
  lint_command: "pip install -e '.[dev]' && ruff check . && mypy ."
  test_command: "pytest -q"
  build_command: "python -m build"
```

### Go

```yaml
with:
  go_version: "1.22"
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

### Java / Gradle (Android)

```yaml
with:
  java_version: "17"
  lint_command: "./gradlew lint"
  test_command: "./gradlew test"
  build_command: ""
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

## Repos That Need the Trigger Fix

These repos have `pull_request` in `ci.yml` **and** `pr-gate.yml` — every push triggers 2× CI:

| Repo | Stack | Fix |
|------|-------|-----|
| scholar-path | Node | Remove `pull_request` from `ci.yml` |
| agentvault | Go | Remove `pull_request` from `ci.yml` |
| spank | Go + Flutter | Remove `pull_request` from `ci.yml` |
| orthodox-calendar | Node + Python | Separate PR triggers |
| automated-plant-monitoring | Python | Remove PR from `ci.yml` |
| openclaw-ai-factory | Python | Remove PR from `ci.yml` |
| scan-context | Node + Python + Rust | Remove PR from `ci.yml` |
| dir-sync | Python | Remove PR from `ci.yml` |
| denial-shield | Java | Remove PR from `ci.yml` |

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

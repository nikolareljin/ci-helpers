# ci-helpers

Shared GitHub Actions workflows and Bash helpers for CI across multiple repos.

Includes:
- Reusable workflows for CI, PR gating, and deploys.
- Reusable scan workflows for Gitleaks, Trivy, Docker (Trivy/Snyk), and language scans.
- Composite actions for semver comparison and release tag checks.
- Composite actions for Trivy, Gitleaks, and WordPress plugin-check scans.
- Vendored [`script-helpers`](https://github.com/nikolareljin/script-helpers) to reuse common Bash logging/utilities.
- Preset workflows for common stacks (Java, C#, Node, Python, PHP, Go, React, Docker, Playwright, Cypress).
- Optional E2E runs (Playwright/Cypress) via `e2e_command`.

## Docs

See detailed usage, inputs, and examples in:
- [Docs index](docs/README.md)
- [Reusable workflows](docs/workflows.md)
- [Presets](docs/presets.md)
- [Composite actions](docs/actions.md)
- [Examples](docs/examples.md)
- [Usage guide](docs/usage.md)

## Quick Start

1) Create `.github/workflows/ci.yml` in your repo:

```yaml
name: CI
on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/node.yml@v0.1.0
    with:
      node_version: "20"
```

2) Commit and push. GitHub will run the workflow on PRs and main.

3) Need E2E? Add an `e2e_command` (runs after Docker if set). See [presets](docs/presets.md) and [examples](docs/examples.md) for more patterns:

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/playwright.yml@v0.1.0
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx playwright test'"
```

## Layout

- `.github/workflows/ci.yml`: reusable CI workflow (lint/test/build/docker/extra)
- `.github/workflows/pr-gate.yml`: reusable PR gate workflow with optional release tag checks
- `.github/workflows/deploy.yml`: reusable deploy workflow
- `.github/workflows/php-scan.yml`: reusable PHP scan workflow (unit, framework lint, WP-CLI scan)
- `.github/workflows/python-scan.yml`: reusable Python scan workflow (unit + Django)
- `.github/workflows/go-scan.yml`: reusable Go scan workflow (tests + gosec)
- `.github/workflows/rust-scan.yml`: reusable Rust scan workflow (tests + audit)
- `.github/workflows/java-scan.yml`: reusable Java scan workflow (tests + dependency check)
- `.github/workflows/csharp-scan.yml`: reusable C# scan workflow (tests + vulnerable packages)
- `.github/workflows/node-scan.yml`: reusable Node.js scan workflow (lint/test/audit)
- `.github/workflows/react-scan.yml`: reusable React scan workflow (lint/test/build/audit)
- `.github/workflows/vue-scan.yml`: reusable Vue scan workflow (lint/test/build/audit)
- `.github/workflows/docker-scan.yml`: reusable Docker scan workflow (Trivy + Snyk)
- `.github/workflows/trivy-scan.yml`: reusable Trivy scan workflow
- `.github/workflows/gitleaks-scan.yml`: reusable Gitleaks scan workflow
- `.github/workflows/wp-plugin-check.yml`: reusable WordPress plugin-check workflow
- `.github/actions/semver-compare`: composite action for semver comparison
- `.github/actions/check-release-tag`: composite action for release tag guard
- `.github/actions/trivy-scan`: composite action for Trivy scanning
- `.github/actions/gitleaks-scan`: composite action for Gitleaks scanning
- `.github/actions/wp-plugin-check`: composite action for WordPress plugin-check
- `scripts/`: bash utilities used by actions
- `vendor/script-helpers`: vendored helper scripts from [`script-helpers`](https://github.com/nikolareljin/script-helpers) (sync via `scripts/sync_script_helpers.sh`)
- `.github/workflows/presets/*.yml`: reusable stack presets

## Reusable workflow examples

PR gate example:

```yaml
name: PR
on:
  pull_request:

jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@v0.1.0
    with:
      node_version: "20"
      lint_command: "npm ci && npm run lint"
      test_command: "npm test"
      build_command: "npm run build"
      e2e_command: "npm run e2e"
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
```

CI example (push/main):

```yaml
name: CI
on:
  push:
    branches: [ main ]

jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
    with:
      python_version: "3.12"
      test_command: "pip install -r requirements.txt && pytest"
      e2e_command: "python -m pytest tests/e2e"
```

## Preset usage by language/framework

Node.js:

```yaml
jobs:
  node:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/node.yml@v0.1.0
    with:
      node_version: "20"
```

React:

```yaml
jobs:
  react:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/react.yml@v0.1.0
    with:
      node_version: "20"
      test_command: "npm test -- --watchAll=false"
      e2e_command: "npm run e2e"
```

Playwright:

```yaml
jobs:
  playwright:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/playwright.yml@v0.1.0
    with:
      node_version: "20"
```

Cypress:

```yaml
jobs:
  cypress:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/cypress.yml@v0.1.0
    with:
      node_version: "20"
```

Python:

```yaml
jobs:
  python:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/python.yml@v0.1.0
    with:
      python_version: "3.12"
      lint_command: "python -m pip install -r requirements.txt"
      test_command: "python -m pytest"
```

PHP:

```yaml
jobs:
  php:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/php.yml@v0.1.0
    with:
      php_version: "8.2"
      lint_command: "composer install --no-interaction --prefer-dist"
      test_command: "vendor/bin/phpunit"
```

Go:

```yaml
jobs:
  go:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/go.yml@v0.1.0
    with:
      go_version: "1.22"
      test_command: "go test ./..."
      build_command: "go build ./..."
```

Java (Maven defaults):

```yaml
jobs:
  java:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/java.yml@v0.1.0
    with:
      java_version: "17"
      test_command: "mvn -B test"
      build_command: "mvn -B package"
```

C# (.NET):

```yaml
jobs:
  csharp:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/csharp.yml@v0.1.0
    with:
      dotnet_version: "8.0.x"
      test_command: "dotnet test"
      build_command: "dotnet build -c Release"
```

Docker:

```yaml
jobs:
  docker:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/docker.yml@v0.1.0
    with:
      docker_command: "docker build ."
```

Notes for presets:
- Defaults assume common commands per stack; override `lint_command`, `test_command`, `build_command`, or `docker_command` as needed.
- Use `e2e_command` for Playwright or Cypress (default presets use Yarn + `start-server-and-test`).
- `e2e_command` runs after `docker_command` if both are set.

Deploy example:

```yaml
name: Deploy
on:
  workflow_dispatch:

jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@v0.1.0
    with:
      deploy_command: "./scripts/deploy.sh"
```

## Composite action examples

Semver compare:

```yaml
- name: Compare versions
  id: semver
  uses: nikolareljin/ci-helpers/.github/actions/semver-compare@v0.1.0
  with:
    version_a: "1.2.3"
    version_b: "1.3.0"

- name: Use result
  run: echo "Result: ${{ steps.semver.outputs.result }}"  # lt, eq, or gt
```

Release tag guard (release/X.Y.Z):

```yaml
- name: Guard release tag
  uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@v0.1.0
  with:
    release_branch: ${{ github.head_ref }}
```

## Notes

- The PR gate only blocks if your branch protection requires its status checks.
- `check-release-tag` expects branch naming `release/X.Y.Z` or `release/vX.Y.Z`.
- Update vendored `script-helpers` with:
  - `./scripts/sync_script_helpers.sh`
  - Optional overrides: `SCRIPT_HELPERS_REPO_URL=...` and `SCRIPT_HELPERS_REF=...`
  - Source repo: `https://github.com/nikolareljin/script-helpers`

## Using from other repositories

1) Create a workflow in your repo (for example `.github/workflows/ci.yml`) and call a reusable workflow:

```yaml
name: CI
on:
  push:
    branches: [ main ]

jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/node.yml@v0.1.0
```

2) Pin to a tag or commit SHA:

```yaml
uses: nikolareljin/ci-helpers/.github/workflows/presets/python.yml@v0.1.0
```

3) Add/override commands and versions as needed:

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
    with:
      node_version: "20"
      lint_command: "npm ci && npm run lint"
      test_command: "npm test"
      build_command: "npm run build"
```

4) For PR blocking, add branch protection rules in your repo:
- Settings → Branches → Branch protection rules
- Require status checks to pass before merging
- Select the workflow job name you use (for example `gate` or `ci`)

## Clone locally (optional)

```bash
git clone git@github.com:nikolareljin/ci-helpers.git
cd ci-helpers
```

HTTPS alternative:

```bash
git clone https://github.com/nikolareljin/ci-helpers.git
cd ci-helpers
```

Use this when you want to update workflows, actions, or sync vendored helpers.

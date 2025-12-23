# Reusable Workflows

This repo exposes reusable workflows via `workflow_call`. You consume them from
your own repo by referencing this repo path and a tag or commit SHA.

All workflows use Bash with `set -euo pipefail` for the commands you pass in.
All commands run inside `inputs.working_directory` (default `"."`).

## ci.yml

Workflow: `.github/workflows/ci.yml`

Purpose: Run lint, test, build, optional Docker, and optional E2E commands.

Execution order:
1) Lint
2) Test
3) Build
4) Docker
5) E2E
6) Extra

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version` (string, default `""`)
- `java_version` (string, default `""`)
- `dotnet_version` (string, default `""`)
- `python_version` (string, default `""`)
- `go_version` (string, default `""`)
- `php_version` (string, default `""`)
- `lint_command` (string, default `""`)
- `test_command` (string, default `""`)
- `build_command` (string, default `""`)
- `docker_command` (string, default `""`)
- `e2e_command` (string, default `""`)
- `extra_command` (string, default `""`)

Example (Node + E2E with Playwright):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
    with:
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      build_command: "yarn build"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx playwright test'"
```

Example (Docker build + E2E):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```

## pr-gate.yml

Workflow: `.github/workflows/pr-gate.yml`

Purpose: Run a PR gate that can include release tag checks plus CI steps.

Execution order:
1) Release tag check (optional)
2) Lint
3) Test
4) Build
5) Docker
6) E2E
7) Extra

Inputs:
- All CI inputs (same as `ci.yml`)
- `check_release_tag` (boolean, default `false`)
- `release_branch` (string, default `""`)

Example (PR gate with release tag check + E2E):

```yaml
jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@v0.1.0
    with:
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
```

## deploy.yml

Workflow: `.github/workflows/deploy.yml`

Purpose: Run a deployment command with optional runtime setup.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version` (string, default `""`)
- `java_version` (string, default `""`)
- `dotnet_version` (string, default `""`)
- `python_version` (string, default `""`)
- `go_version` (string, default `""`)
- `php_version` (string, default `""`)
- `deploy_command` (string, required)

Example:

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@v0.1.0
    with:
      node_version: "20"
      deploy_command: "./scripts/deploy.sh"
```

## Pinning versions

You should pin to a tag or commit SHA:

```yaml
uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
```

Using a commit SHA is safest for reproducibility:

```yaml
uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@<commit-sha>
```

## Working directory

If your repository is a monorepo, set `working_directory` so commands run in the
package folder:

```yaml
with:
  working_directory: "apps/web"
  node_version: "20"
  test_command: "yarn test"
```

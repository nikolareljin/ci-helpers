# Reusable Workflows

This repo exposes reusable workflows via `workflow_call`. You consume them from
your own repo by referencing this repo path and a tag or commit SHA.

Related docs:
- [Presets](presets.md)
- [Composite actions](actions.md)
- [Examples](examples.md)

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
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@0.1.1
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
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@0.1.1
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
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@0.1.1
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
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@0.1.1
    with:
      node_version: "20"
      deploy_command: "./scripts/deploy.sh"
```

## trivy-scan.yml

Workflow: `.github/workflows/trivy-scan.yml`

Purpose: Run Trivy filesystem scan with optional SARIF upload.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `format` (string, default `sarif`)
- `output` (string, default `trivy-results.sarif`)
- `severity` (string, default `CRITICAL,HIGH`)
- `ignore_unfixed` (string, default `"true"`)
- `vuln_type` (string, default `os,library`)
- `fail_on_findings` (boolean, default `false`)
- `upload_sarif` (boolean, default `true`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `trivy-results`)

Example:

```yaml
jobs:
  trivy:
    uses: nikolareljin/ci-helpers/.github/workflows/trivy-scan.yml@0.1.1
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: true
```

## gitleaks-scan.yml

Workflow: `.github/workflows/gitleaks-scan.yml`

Purpose: Run Gitleaks and emit a report.

Note: When findings are detected, the workflow prints Leak-Lock links for help
removing leaked credentials.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `report_format` (string, default `sarif`)
- `output` (string, default `results.sarif`)
- `config_path` (string, default `""`)
- `fail_on_findings` (boolean, default `false`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `gitleaks-report`)

Note: `gitleaks-action` emits SARIF only; other `report_format` values are ignored, and `scan_path`/`config_path` are not honored (it auto-detects `.gitleaks.toml`).

Example:

```yaml
jobs:
  gitleaks:
    uses: nikolareljin/ci-helpers/.github/workflows/gitleaks-scan.yml@0.1.1
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: true
```

## php-scan.yml

Workflow: `.github/workflows/php-scan.yml`

Purpose: Run PHP unit tests, framework linting, and a WP-CLI scan with demo content.

Inputs (selected):
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `php_version` (string, default `8.2`)
- `composer_command` (string, default `composer install --no-interaction --prefer-dist`)
- `unit_command` (string, default `vendor/bin/phpunit`)
- `lint_wp_command` (string, default `vendor/bin/phpcs --standard=WordPress --extensions=php`)
- `lint_drupal_command` (string, default `vendor/bin/phpcs --standard=Drupal --extensions=php`)
- `lint_laravel_command` (string, default `vendor/bin/pint`)
- `wp_cli_scan` (boolean, default `true`)
- `wp_root` (string, default `wp-cli-site`)

Example:

```yaml
jobs:
  php_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/php-scan.yml@0.1.1
```

## python-scan.yml

Workflow: `.github/workflows/python-scan.yml`

Purpose: Run Python lint, unit tests, and Django tests when a Django project is detected.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `python_version` (string, default `3.12`)
- `install_command` (string, default `if [ -f requirements.txt ]; then python -m pip install -r requirements.txt; elif [ -f pyproject.toml ]; then python -m pip install pyinstaller && python -m pip install .; fi`)
- `lint_command` (string, default `python -m pip install ruff && ruff check .`)
- `unit_command` (string, default `python -m pip install pytest && python -m pytest`)
- `django_command` (string, default `python manage.py test`, only runs when Django is detected)

Example:

```yaml
jobs:
  python_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/python-scan.yml@0.1.1
```

## go-scan.yml

Workflow: `.github/workflows/go-scan.yml`

Purpose: Run Go lint, tests, and gosec scanning.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `go_version` (string, default `1.22`)
- `lint_command` (string, default `test -z "$(gofmt -l .)" && go vet ./...`)
- `test_command` (string, default `go mod download && go test ./...`)
- `gosec_args` (string, default `./...`)

Example:

```yaml
jobs:
  go_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/go-scan.yml@0.1.1
```

## rust-scan.yml

Workflow: `.github/workflows/rust-scan.yml`

Purpose: Run Rust lint, tests, and cargo-audit.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `rust_toolchain` (string, default `stable`)
- `rust_components` (string, default `rustfmt, clippy`)
- `lint_command` (string, default `cargo fmt -- --check && cargo clippy -- -D warnings`)
- `test_command` (string, default `cargo fetch && cargo test`)
- `audit_command` (string, default `cargo audit`)

Example:

```yaml
jobs:
  rust_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/rust-scan.yml@0.1.1
```

## java-scan.yml

Workflow: `.github/workflows/java-scan.yml`

Purpose: Run Java lint, tests, and OWASP dependency checks.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `java_version` (string, default `17`)
- `lint_command` (string, default `mvn -B -DskipTests checkstyle:check`)
- `test_command` (string, default `mvn -B test`)
- `dependency_check_command` (string, default `mvn -B org.owasp:dependency-check-maven:check`)

Example:

```yaml
jobs:
  java_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/java-scan.yml@0.1.1
```

## csharp-scan.yml

Workflow: `.github/workflows/csharp-scan.yml`

Purpose: Run .NET lint, tests, and list vulnerable packages.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `dotnet_version` (string, default `8.0.x`)
- `lint_command` (string, default `dotnet tool install -g dotnet-format && export PATH="$PATH:$HOME/.dotnet/tools" && dotnet-format --verify-no-changes`)
- `test_command` (string, default `dotnet restore && dotnet test`)
- `vuln_command` (string, default `dotnet list package --vulnerable --include-transitive`)

Example:

```yaml
jobs:
  csharp_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/csharp-scan.yml@0.1.1
```

## node-scan.yml

Workflow: `.github/workflows/node-scan.yml`

Purpose: Run Node.js lint/test/audit and optional build.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `20`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `""`)

Example:

```yaml
jobs:
  node_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/node-scan.yml@0.1.1
```

## react-scan.yml

Workflow: `.github/workflows/react-scan.yml`

Purpose: Run React lint/test/build with npm audit.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `20`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run lint`)
- `test_command` (string, default `npm test -- --watchAll=false`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `npm run build`)

Example:

```yaml
jobs:
  react_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/react-scan.yml@0.1.1
```

## vue-scan.yml

Workflow: `.github/workflows/vue-scan.yml`

Purpose: Run Vue lint/test/build with npm audit.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `20`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `npm run build`)

Example:

```yaml
jobs:
  vue_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/vue-scan.yml@0.1.1
```

## docker-scan.yml

Workflow: `.github/workflows/docker-scan.yml`

Purpose: Build a Docker image and scan with Trivy and Snyk.

Note: Snyk requires a `SNYK_TOKEN` secret.

Inputs (selected):
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `image_name` (string, default `ci-image:latest`)
- `dockerfile` (string, default `Dockerfile`)
- `context` (string, default `"."`)
- `trivy_severity` (string, default `CRITICAL,HIGH`)
- `fail_on_findings` (boolean, default `true`)
- `run_snyk` (boolean, default `true`)

Example:

```yaml
jobs:
  docker_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@0.1.1
    secrets:
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

## auto-tag-release.yml

Workflow: `.github/workflows/auto-tag-release.yml`

Purpose: Auto-tag releases when a `release/X.Y.Z` PR is merged into `main` or `master`.

Notes:
- Runs on pushes to `main` or `master` and detects the merged PR for squash/merge commits.
- Checks if the tag already exists before creating and pushing it.

Example:

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@0.1.1
```

## wp-plugin-check.yml

Workflow: `.github/workflows/wp-plugin-check.yml`

Purpose: Run WordPress plugin-check via Docker, with optional PHPUnit/lint.

Note: Requires Docker on the runner and a compose file that mounts the plugin.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `compose_file` (string, default `test/docker-compose.yml`)
- `plugin_slug` (string, required)
- `plugin_src` (string, default `"."`)
- `plugin_src_env` (string, default `PLUGIN_SRC`)
- `out_dir` (string, default `test/tmp`)
- `php_version` (string, default `""`)
- `php_lint_command` (string, default `""`)
- `phpcs_warning_command` (string, default `""`)
- `phpunit_command` (string, default `""`)
- `fail_on_findings` (boolean, default `false`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `plugin-check-results`)

Example:

```yaml
jobs:
  plugin-check:
    uses: nikolareljin/ci-helpers/.github/workflows/wp-plugin-check.yml@0.1.1
    with:
      plugin_slug: my-plugin
      plugin_src_env: MY_PLUGIN_SRC
      plugin_src: "."
      php_version: "8.2"
      phpunit_command: "vendor/bin/phpunit"
      phpcs_warning_command: "vendor/bin/phpcs -p -s --warning-severity=1 --error-severity=0 ."
      fail_on_findings: true
      upload_artifact: true
```

## Pinning versions

You should pin to a tag or commit SHA:

```yaml
uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@0.1.1
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

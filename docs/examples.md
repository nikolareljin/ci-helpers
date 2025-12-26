# Examples

This file provides extended examples that combine multiple inputs and common
real-world patterns.

Related docs:
- [Reusable workflows](workflows.md)
- [Presets](presets.md)
- [Composite actions](actions.md)

## Monorepo (subdirectory)

```yaml
jobs:
  web:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@0.1.1
    with:
      working_directory: "apps/web"
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      build_command: "yarn build"
```

## Playwright with start-server-and-test (custom port)

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/playwright.yml@0.1.1
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:4173 'npx playwright test'"
```

## Cypress with start-server-and-test (custom script)

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/cypress.yml@0.1.1
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev:ci' http://localhost:3000 'npx cypress run'"
```

## Docker build + E2E

E2E always runs after Docker when both are set.

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@0.1.1
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```

## PR gate with release tag check

```yaml
jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@0.1.1
    with:
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
      node_version: "20"
      test_command: "yarn test"
```

## Deploy with runtime setup

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@0.1.1
    with:
      node_version: "20"
      deploy_command: "./scripts/deploy.sh"
```

## Trivy scan + SARIF upload

```yaml
jobs:
  trivy:
    uses: nikolareljin/ci-helpers/.github/workflows/trivy-scan.yml@0.1.1
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: true
```

## Gitleaks scan

```yaml
jobs:
  gitleaks:
    uses: nikolareljin/ci-helpers/.github/workflows/gitleaks-scan.yml@0.1.1
    with:
      scan_path: "."
      fail_on_findings: true
```

## PHP scan (unit + framework lint + WP-CLI)

```yaml
jobs:
  php_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/php-scan.yml@0.1.1
    with:
      php_version: "8.2"
```

## Docker scan (Trivy + Snyk)

```yaml
jobs:
  docker_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@0.1.1
    with:
      image_name: "app:ci"
    secrets:
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

## Composite actions (Gitleaks + Trivy)

```yaml
jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Gitleaks scan
        uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@0.1.1
        with:
          scan_path: "."
          fail_on_findings: "true"
      - name: Trivy scan
        uses: nikolareljin/ci-helpers/.github/actions/trivy-scan@0.1.1
        with:
          scan_path: "."
          format: "sarif"
          output: "trivy-results.sarif"
          fail_on_findings: "true"
          upload_sarif: "true"
```

## Release tag guard (PR)

```yaml
jobs:
  release_guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Guard release tag
        id: release_guard
        uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@0.1.1
        with:
          release_branch: ${{ github.head_ref }}
          fetch_tags: true
      - name: Use version
        run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

## Release tag guard (release)

```yaml
jobs:
  release_guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Guard release tag
        id: release_guard
        uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@0.1.1
        with:
          release_branch: ${{ github.ref_name }}
          fetch_tags: true
      - name: Use version
        run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

## Auto-tag release

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@0.1.1
```

## WordPress plugin check + standalone PHPUnit

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

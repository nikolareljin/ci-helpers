# Composite Actions

These composite actions are intended for reuse inside your workflows.

Related docs:
- [Reusable workflows](workflows.md)
- [Examples](examples.md)

## semver-compare

Path: `.github/actions/semver-compare`

Purpose: Compare two semver strings and return `lt`, `eq`, or `gt`.

Inputs:
- `version_a` (required)
- `version_b` (required)

Outputs:
- `result` (`lt`, `eq`, or `gt`)

Example:

```yaml
- name: Compare versions
  id: semver
  uses: nikolareljin/ci-helpers/.github/actions/semver-compare@v0.1.0
  with:
    version_a: "1.2.3"
    version_b: "1.4.0"

- name: Use result
  run: echo "Result: ${{ steps.semver.outputs.result }}"
```

## check-release-tag

Path: `.github/actions/check-release-tag`

Purpose: Fail if a `release/X.Y.Z` (or `release/vX.Y.Z`) branch already has a tag.

Inputs:
- `release_branch` (optional, defaults to `GITHUB_HEAD_REF`/`GITHUB_REF_NAME`)
- `repo_dir` (optional, defaults to `GITHUB_WORKSPACE`)
- `fetch_tags` (optional, default `"true"`)

Outputs:
- `version` (parsed from the release branch, e.g. `1.2.3`)

Example:

```yaml
- name: Guard release tag
  id: release_guard
  uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@v0.1.0
  with:
    release_branch: ${{ github.head_ref }}
    fetch_tags: true

- name: Use version
  run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

Notes:
- The guard expects branch naming `release/X.Y.Z` or `release/vX.Y.Z`.

## trivy-scan

Path: `.github/actions/trivy-scan`

Purpose: Run Trivy filesystem scans with optional SARIF upload.

Inputs:
- `scan_path` (default `"."`)
- `format` (default `sarif`)
- `output` (default `trivy-results.sarif`)
- `severity` (default `CRITICAL,HIGH`)
- `ignore_unfixed` (default `"true"`)
- `vuln_type` (default `os,library`)
- `fail_on_findings` (default `"false"`)
- `upload_sarif` (default `"true"`)

Example:

```yaml
- name: Trivy scan
  uses: nikolareljin/ci-helpers/.github/actions/trivy-scan@v0.1.0
  with:
    scan_path: "."
    fail_on_findings: "true"
```

## gitleaks-scan

Path: `.github/actions/gitleaks-scan`

Purpose: Run Gitleaks scan and generate a report.

Note: When findings are detected, the action prints Leak-Lock links for help
removing leaked credentials.

Inputs:
- `scan_path` (default `"."`)
- `report_format` (default `json`)
- `output` (default `gitleaks-report.json`)
- `config_path` (default `""`)
- `fail_on_findings` (default `"false"`)

Example:

```yaml
- name: Gitleaks scan
  uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@v0.1.0
  with:
    scan_path: "."
    fail_on_findings: "true"
```

## wp-plugin-check

Path: `.github/actions/wp-plugin-check`

Purpose: Run WordPress plugin-check in Docker and optional standalone PHPUnit.

Note: Requires Docker on the runner and a compose file that mounts the plugin.

Inputs (selected):
- `compose_file` (default `test/docker-compose.yml`)
- `plugin_slug` (required)
- `plugin_src` (default `"."`)
- `plugin_src_env` (default `PLUGIN_SRC`)
- `out_dir` (default `test/tmp`)
- `php_version` (optional for lint/PHPUnit)
- `php_lint_command` (optional, errors only)
- `phpcs_warning_command` (optional, non-blocking)
- `phpunit_command` (optional, standalone)
- `fail_on_findings` (default `"false"`)

Example:

```yaml
- name: Plugin check
  uses: nikolareljin/ci-helpers/.github/actions/wp-plugin-check@v0.1.0
  with:
    plugin_slug: my-plugin
    plugin_src_env: MY_PLUGIN_SRC
    plugin_src: "."
    php_version: "8.2"
    phpunit_command: "vendor/bin/phpunit"
    fail_on_findings: "true"
```

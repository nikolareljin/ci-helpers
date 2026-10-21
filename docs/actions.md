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
  uses: nikolareljin/ci-helpers/.github/actions/semver-compare@production
  with:
    version_a: "1.2.3"
    version_b: "1.4.0"

- name: Use result
  run: echo "Result: ${{ steps.semver.outputs.result }}"
```

## check-release-tag

Path: `.github/actions/check-release-tag`

Purpose: Fail if a `release/[v]X.Y.Z`, `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N` branch already has a tag.

Inputs:

- `release_branch` (optional, defaults to `GITHUB_HEAD_REF`/`GITHUB_REF_NAME`)
- `repo_dir` (optional, defaults to `GITHUB_WORKSPACE`)
- `fetch_tags` (optional, default `"true"`)

Outputs:

- `version` (parsed from the release branch, e.g. `1.2.3` or `1.2.3-rc.1`)

Example:

```yaml
- name: Guard release tag
  id: release_guard
  uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@production
  with:
    release_branch: ${{ github.head_ref }}
    fetch_tags: true

- name: Use version
  run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

Notes:

- The guard expects branch naming `release/[v]X.Y.Z`, `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N`.

## release-notes

Path: `.github/actions/release-notes`

Purpose: Generate release notes from git history with optional binary links.

Inputs:

- `repo_dir` (default `GITHUB_WORKSPACE`)
- `since_tag` (default `""`, uses latest tag when omitted)
- `release_tag` (default `GITHUB_REF_NAME`)
- `binary_links` (default `""`, `label|filename` per line)
- `binary_base_url` (default `""`, uses repo releases/download/<tag>)

Outputs:

- `notes` (generated markdown)

Example:

```yaml
- name: Generate release notes
  id: notes
  uses: nikolareljin/ci-helpers/.github/actions/release-notes@production
  with:
    binary_links: |
      Linux|myapp-linux
      macOS|myapp-mac

- name: Use notes
  run: echo "${{ steps.notes.outputs.notes }}"
```

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
  uses: nikolareljin/ci-helpers/.github/actions/trivy-scan@production
  with:
    scan_path: "."
    fail_on_findings: "true"
```

With `upload_sarif: "true"` the SARIF is uploaded even when the scan step fails
on findings, so a failing run still shows its results in the Security tab.

## gitleaks-scan

Path: `.github/actions/gitleaks-scan`

Purpose: Run Gitleaks scan and generate a report.

Note: When findings are detected, the action prints a link to Leak-Lock for help
removing leaked credentials.

Inputs:

- `scan_path` (default `"."`)
- `report_format` (default `sarif`)
- `output` (default `results.sarif`)
- `gitleaks_version` (default `v8.30.1`)
- `config_path` (default `""`)
- `fail_on_findings` (default `"false"`)
- `upload_artifact` (default `"false"`)
- `artifact_name` (default `gitleaks-report`)

Notes:

- The gitleaks release archive is verified against the `checksums.txt` published
  with the same release before it runs; a mismatch fails the step.
- Reports are written with `--redact`: findings, rule IDs, files, lines and
  fingerprints are kept, secret values are not.
- With `config_path` empty, gitleaks reads `.gitleaks.toml` (and, always,
  `.gitleaksignore`) from the checked-out tree. On `pull_request` events those
  files come from the PR, so the action emits a warning when the PR changes a
  `.gitleaks.toml`, `.gitleaksignore` or the `config_path` file. The check never
  fails the step; on a shallow checkout where the base cannot be diffed it emits
  a notice instead.

Example:

```yaml
- name: Gitleaks scan
  uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@production
  with:
    scan_path: "."
    fail_on_findings: "true"
    upload_artifact: "true"
```

## data-safety-scan

Path: `.github/actions/data-safety-scan`

Purpose: Reject sensitive-key fields in JSON data files before they ship with
application data.

Inputs:

- `scan_path` (required): Directory to scan recursively for `*.json` files.

Example:

```yaml
- uses: actions/checkout@v5
- name: Data safety scan
  uses: nikolareljin/ci-helpers/.github/actions/data-safety-scan@production
  with:
    scan_path: backend/app/data
```

The action reports each matching JSON file as a workflow error and fails when it
finds any of these keys: `api_key`, `api_secret`, `password`, `passwd`, `token`,
`secret`, `auth`, `cookie`, `session`, `credential`, or `private_key`.
A JSON file it cannot read is reported and fails the scan with exit code 2,
rather than counting as clean.

## macos-sign

Path: `.github/actions/macos-sign`

Purpose: Import an Apple p12 certificate into a temporary keychain and export
all Tauri-required Apple environment variables to `GITHUB_ENV`. Call this
action **before** `cargo tauri build` on a macOS runner. Keychain cleanup is
the **caller's responsibility** — add an `if: always()` cleanup step to your
build job after the build (see Notes below).

Inputs:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `certificate_base64` | yes | — | Base64-encoded `.p12` Apple Developer certificate |
| `certificate_password` | yes | — | Password for the `.p12` |
| `signing_identity` | yes | — | `Developer ID Application: Name (TEAMID)` |
| `team_id` | yes | — | 10-character Apple Team ID |
| `apple_id` | no | `""` | Apple ID email for `notarytool` (leave empty to skip notarization setup) |
| `app_password` | no | `""` | App-specific password for `notarytool` |
| `keychain_name` | no | `ci-build.keychain-db` | Name of the temporary keychain |
| `export_env` | no | `"false"` | Opt-in. `"true"` also writes the secrets to `GITHUB_ENV`; see below |

Environment variables written to `GITHUB_ENV`: `APPLE_SIGNING_IDENTITY`,
`APPLE_TEAM_ID` and `CI_MACOS_KEYCHAIN` always. With `export_env: "true"`
also `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD` and (when `apple_id` is
set) `APPLE_ID` + `APPLE_PASSWORD`. Every later step of the job can read what
is in `GITHUB_ENV`, including the caller's build and its dependencies, so the
default `"false"` leaves them out: give the secrets to the build step's `env:`,
as `tauri-release.yml` does.

`export_env` is off by default. Turn it on only when the build step cannot take
`env:`, for example a third-party action that reads the variables itself. The
cost: every later step in the job, including dependency installs and build
scripts, can read the certificate and passwords. Only an exact `"true"` enables
it.

Example (inside `tauri-release.yml` or any macOS build job):

```yaml
- name: Set up macOS signing
  uses: nikolareljin/ci-helpers/.github/actions/macos-sign@production
  with:
    certificate_base64: ${{ secrets.APPLE_CERTIFICATE }}
    certificate_password: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
    signing_identity: ${{ secrets.APPLE_SIGNING_IDENTITY }}
    team_id: ${{ secrets.APPLE_TEAM_ID }}
    apple_id: ${{ secrets.APPLE_ID }}
    app_password: ${{ secrets.APPLE_APP_PASSWORD }}

- name: Build Tauri app
  run: cargo tauri build --target universal-apple-darwin
```

Notes:

- All secret inputs are masked with `::add-mask::` before any output.
- **Keychain cleanup is the caller's responsibility.** Composite actions have
  no `post:` hook, so any cleanup step inside the action would run immediately
  after import — before your build step — deleting the keychain too early.
  Add this to your build job (after `cargo tauri build`):
  ```yaml
  - name: Cleanup macOS keychain
    if: always()
    shell: bash
    run: security delete-keychain "${{ env.CI_MACOS_KEYCHAIN }}" 2>/dev/null || true
  ```
  `tauri-release.yml` already includes this step.
- Tauri reads `APPLE_CERTIFICATE` and the other env vars automatically; no
  additional `tauri.conf.json` configuration is required for signing.

## windows-sign

Path: `.github/actions/windows-sign`

Purpose: Configure Windows code signing for Tauri builds. Supports three
modes. [Windows signing](windows-signing.md) says how to get a certificate
for each and how to turn pfx on.

| Mode | Cost | What it signs | How |
|------|------|---------------|-----|
| `tauri_updater` | **Free** | `.sig` updater bundles (ED25519) | Checks the key; with `export_env: "true"` also sets `TAURI_SIGNING_PRIVATE_KEY` + `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` in `GITHUB_ENV` |
| `pfx` | CA price, or free with a private CA | MSI + EXE Authenticode | Without `files_folder`: checks the PFX opens and holds an unexpired code-signing key. With it: signs, timestamps and verifies every `.exe` and `.msi` under it |
| `azure` | Paid | MSI + EXE Authenticode | Checks the credentials; with `export_env: "true"` also writes them to `GITHUB_ENV`. Signing is a post-build `azure/trusted-signing-action` step |

Inputs:

| Input | Required for | Default | Description |
|-------|-------------|---------|-------------|
| `sign_mode` | all | - | `tauri_updater`, `pfx` or `azure`; anything else fails the step |
| `tauri_signing_private_key` | `tauri_updater` | — | Base64 or raw ED25519 private key |
| `tauri_signing_private_key_password` | no | `""` | Password for the updater key |
| `certificate_base64` | `pfx` | - | Base64 of the `.pfx` |
| `certificate_password` | `pfx` | - | PFX password |
| `timestamp_server` | no | `""` | RFC 3161 URL; empty uses `http://timestamp.digicert.com` |
| `files_folder` | no | `""` | `pfx`: folder to sign (recursive `.exe`, `.msi`); empty only checks the PFX |
| `verify_trust` | no | `"true"` | `pfx`: require `signtool verify /pa`; `"false"` for a private CA or self-signed certificate |
| `azure_tenant_id` | `azure` | — | Azure tenant ID |
| `azure_client_id` | `azure` | — | Service principal client ID |
| `azure_client_secret` | `azure` | — | Service principal secret |
| `azure_endpoint` | `azure` | — | Trusted Signing endpoint URL |
| `azure_code_signing_account` | `azure` | — | Account name |
| `azure_cert_profile` | `azure` | — | Certificate profile name |
| `export_env` | no | `"false"` | Opt-in. `"true"` writes the updater key or the Azure values to `GITHUB_ENV`; see Notes |

Example — free updater signing (most common):

```yaml
- name: Set up Windows signing
  uses: nikolareljin/ci-helpers/.github/actions/windows-sign@production
  with:
    sign_mode: tauri_updater
    tauri_signing_private_key: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
    tauri_signing_private_key_password: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}

- name: Build Tauri app
  run: cargo tauri build
```

Notes:

- All secret inputs are masked with `::add-mask::` before any output.
- `export_env` is off by default: pass the updater key to the build step's
  `env:` and the Azure values to `azure/trusted-signing-action` yourself, as
  `tauri-release.yml` does. Set `"true"` only when a later step must read them
  from the environment and cannot take `env:`. The cost: every later step in
  the job, including dependency installs and build scripts, can read them.
- `pfx` mode signs after the build: run the action once before it (no
  `files_folder`) to fail early on a bad PFX, and once after it with
  `files_folder`. It needs a Windows runner. The PFX is opened from memory,
  never written to disk, and its key is removed from the certificate store
  when the step ends, on failure too. Publicly trusted certificates issued
  since 2023-06-01 have hardware-bound keys and cannot be exported to a
  `.pfx`; see [Windows signing](windows-signing.md).
- `azure` mode: the actual signing happens via `azure/trusted-signing-action`
  in a separate post-build step. This action only checks the credentials.
- Generate a free updater key with: `cargo tauri signer generate -w ~/.tauri/myapp.key`

## pimcore-bundle-check

Path: `.github/actions/pimcore-bundle-check`

Purpose: Run PHPCS, PHPStan and PHPUnit for a Pimcore bundle inside a Docker
Compose stack, with an optional standalone (no-Docker) mode.

Note: Requires Docker on the runner and a compose file that mounts the bundle.
For most repositories the [`pimcore.yml` preset](presets.md#pimcore) is the
better entry point — it wraps this action and adds a PHP version matrix.

Inputs (selected):

- `compose_file` (default `test/docker-compose.yml`)
- `bundle_src` (default `"."`), `bundle_src_env` (default `BUNDLE_SRC`)
- `php_service` (default `php`), `db_service` (default `db`), `db_wait_seconds` (default `"20"`)
- `out_dir` (default `test/tmp`)
- `php_version` (default `""`) — drives the optional standalone steps, and is exported for the Compose stack
- `php_version_env` (default `PHP_VERSION`) — variable `php_version` is exported as; `""` exports nothing
- `composer_command`, `phpcs_command`, `phpstan_command`, `phpunit_command`, `phpunit_coverage_command`
- `fail_on_findings`, `cleanup`

Example:

```yaml
- name: Pimcore bundle check
  uses: nikolareljin/ci-helpers/.github/actions/pimcore-bundle-check@production
  with:
    compose_file: docker-test/docker-compose.yml
    php_version: "8.4"
    phpcs_command: "vendor/bin/phpcs"
    fail_on_findings: "true"
```

`php_version` is exported as `PHP_VERSION` before the stack starts, so the
compose file can build against it:

```yaml
services:
  php:
    build:
      args:
        PHP_VERSION: ${PHP_VERSION:-8.3}
```

Without that, the stack builds whatever its own default is and `php_version`
affects only the standalone steps.

`bundle_src` is resolved to an absolute path and exported as `bundle_src_env`
for the rest of the job, so every later `docker compose` call, including the
Cleanup `down`, can interpolate a compose file that requires it.

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
  uses: nikolareljin/ci-helpers/.github/actions/wp-plugin-check@production
  with:
    plugin_slug: my-plugin
    plugin_src_env: MY_PLUGIN_SRC
    plugin_src: "."
    php_version: "8.4"
    phpunit_command: "vendor/bin/phpunit"
    fail_on_findings: "true"
```

`plugin_src` is resolved from the workspace (not from the compose file's
directory) to an absolute path and exported as `plugin_src_env` for the rest of
the job, so every later `docker compose` call, including Cleanup, sees it.

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

## gitleaks-scan

Path: `.github/actions/gitleaks-scan`

Purpose: Run Gitleaks scan and generate a report.

Note: When findings are detected, the action prints Leak-Lock links for help
removing leaked credentials.

Inputs:
- `scan_path` (default `"."`)
- `report_format` (default `sarif`)
- `output` (default `results.sarif`)
- `config_path` (default `""`)
- `fail_on_findings` (default `"false"`)
- `upload_artifact` (default `"false"`)
- `artifact_name` (default `gitleaks-report`)

Note: `gitleaks-action` emits SARIF only; other `report_format` values are ignored, and `scan_path`/`config_path` are not honored (it auto-detects `.gitleaks.toml`).

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

Environment variables written to `GITHUB_ENV`:
`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`,
`APPLE_TEAM_ID`, and (when `apple_id` is set) `APPLE_ID` + `APPLE_PASSWORD`.

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

Purpose: Configure Windows code signing for Tauri builds. Supports three modes:

| Mode | Cost | What it signs | How |
|------|------|---------------|-----|
| `tauri_updater` | **Free** | `.sig` updater bundles (ED25519) | Sets `TAURI_SIGNING_PRIVATE_KEY` + `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` in `GITHUB_ENV` |
| `pfx` | Paid (OV/EV) | MSI + EXE Authenticode | Imports PFX to cert store, sets `TAURI_WINDOWS_SIGN_COMMAND` via `signtool` |
| `azure` | Paid | MSI + EXE Authenticode | Exports Azure Trusted Signing credentials to `GITHUB_ENV` for post-build action |

Inputs:

| Input | Required for | Default | Description |
|-------|-------------|---------|-------------|
| `sign_mode` | all | — | `tauri_updater`, `pfx`, or `azure` |
| `tauri_signing_private_key` | `tauri_updater` | — | Base64 or raw ED25519 private key |
| `tauri_signing_private_key_password` | no | `""` | Password for the updater key |
| `certificate_base64` | `pfx` | — | Base64-encoded PFX |
| `certificate_password` | `pfx` | — | PFX password |
| `timestamp_server` | no | `https://timestamp.sectigo.com` | RFC 3161 timestamp URL |
| `azure_tenant_id` | `azure` | — | Azure tenant ID |
| `azure_client_id` | `azure` | — | Service principal client ID |
| `azure_client_secret` | `azure` | — | Service principal secret |
| `azure_endpoint` | `azure` | — | Trusted Signing endpoint URL |
| `azure_code_signing_account` | `azure` | — | Account name |
| `azure_cert_profile` | `azure` | — | Certificate profile name |

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

Example — paid PFX Authenticode:

```yaml
- name: Set up Windows signing
  uses: nikolareljin/ci-helpers/.github/actions/windows-sign@production
  with:
    sign_mode: pfx
    certificate_base64: ${{ secrets.WINDOWS_CERTIFICATE }}
    certificate_password: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}
```

Notes:
- All secret inputs are masked with `::add-mask::` before any output.
- **PFX cert cleanup is the caller's responsibility.** Composite actions have
  no `post:` hook; cleanup inside the action would delete the cert before your
  build step runs. Add this to your build job (after `cargo tauri build`):
  ```yaml
  - name: Cleanup Windows certificate
    if: always()
    shell: pwsh
    env:
      THUMB: ${{ env.WINDOWS_CERT_THUMBPRINT }}
      PFX_PATH: ${{ env.WINDOWS_PFX_PATH }}
    run: |
      if ($env:THUMB) { Get-ChildItem "Cert:\CurrentUser\My\$($env:THUMB)" -EA SilentlyContinue | Remove-Item -Force }
      if ($env:PFX_PATH -and (Test-Path $env:PFX_PATH)) { Remove-Item $env:PFX_PATH -Force }
  ```
  `tauri-release.yml` already includes this step.
- `azure` mode: the actual signing happens via `azure/trusted-signing-action`
  in a separate post-build step — this action only exports the credentials.
- Generate a free updater key with: `cargo tauri signer generate -w ~/.tauri/myapp.key`

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
    php_version: "8.2"
    phpunit_command: "vendor/bin/phpunit"
    fail_on_findings: "true"
```

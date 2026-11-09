# Actions

These actions are intended for reuse inside your workflows.

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
  env:
    RESULT: ${{ steps.semver.outputs.result }}
  run: echo "result=$RESULT"
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
  env:
    VERSION: ${{ steps.release_guard.outputs.version }}
  run: echo "version=$VERSION"
```

Notes:

- The guard expects branch naming `release/[v]X.Y.Z`, `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N`.

## trivy-scan

Path: `.github/actions/trivy-scan`

Purpose: Run Trivy filesystem scans with optional SARIF upload.

Trivy is the release binary pinned by version and sha256 in this repository's
`scanner-pins.env`, downloaded and verified by the action; no third-party
action. The vulnerability database is fetched in its own step and the scan runs
with `--skip-db-update --skip-check-update --offline-scan`, and every Trivy
call passes `--disable-telemetry --skip-version-check`.

Inputs:

- `scan_path` (default `"."`)
- `format` (default `sarif`)
- `output` (default `trivy-results.sarif`)
- `severity` (default `CRITICAL,HIGH`)
- `ignore_unfixed` (default `"true"`)
- `vuln_type` (default `os,library`)
- `fail_on_findings` (default `"false"`)
- `scanners` (default `vuln`) - comma-separated Trivy scanners, e.g. `vuln,secret,misconfig`
- `skip_dirs` (default `""`) - comma-separated directories passed to `--skip-dirs`
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

Purpose: Enforce Gitleaks checks without exporting scanner results.

Note: When findings are detected, the action prints a link to Leak-Lock for help
removing leaked credentials.

Inputs:

- `scan_path` (default `"."`)
- `report_format` (default `sarif`, deprecated, no report is exported)
- `output` (default `results.sarif`, deprecated, no file is created)
- `gitleaks_version` (default `v8.30.1`)
- `gitleaks_sha256` (default `""`) - sha256 of the release archive for the runner; required with any version other than `v8.30.1`, whose six archive digests (linux, darwin, windows; x64, arm64) are pinned in the action; with `v8.30.1` it may only repeat the pinned digest, a different one is refused
- `config_path` (default `""`)
- `fail_on_findings` (default `"true"`)
- `upload_artifact` (default `"false"`)
- `artifact_name` (default `gitleaks-report`, deprecated, no artifact is created)

Outputs:

- `gl_bin`: path of the gitleaks binary the action downloaded and verified.
  The action sets no environment variable for later steps; a step that runs
  the same binary reads this output.

Notes:

- The gitleaks release archive is verified before it runs against a sha256
  held in this repository (or `gitleaks_sha256`), never against a checksums
  file fetched from the same release; a mismatch or a missing digest fails
  the step.

The Gitleaks action exports no report. `upload_artifact: true` and
`fail_on_findings: false` are refused before scanning. `output`, `report_format`
and `artifact_name` remain deprecated compatibility inputs and create no caller
report. Scanner errors and findings name Gitleaks and the branch, link
https://nikolareljin.github.io/leak-lock/, and instruct the operator to run
Scan Repository and repository tests locally before pushing. No scanner results,
counts or report paths are logged.

The Gitleaks action installs Python 3.12 to parse reviewed TOML on every runner.
Rule `path` filters are supported. External `[extend]` paths are refused so a
reviewed root configuration cannot load rules from the unreviewed checkout.

PR scans read configuration and ignores from the base commit. Missing base commits
and external configuration extensions refuse the scan. Other Git scans use HEAD.

Example:

```yaml
- name: Gitleaks scan
  uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@production
  with:
    scan_path: "."
    fail_on_findings: "true"
    upload_artifact: "false"
```

## foxguard-scan

Path: `.github/actions/foxguard-scan`

Purpose: Enforce Foxguard static-analysis checks without exporting scanner results.

Note: When findings are detected, the action prints a link to Leak-Lock for help
reproducing and fixing them locally.

Inputs:

- `scan_path` (default `"."`)
- `severity` (default `medium`) - lowest severity that fails the scan: `low`, `medium`, `high` or `critical`
- `config_path` (default `""`) - foxguard config file, relative to the scanned repository; read from the pull request's base commit
- `fail_on_findings` (default `"true"`) - `false` is refused
- `foxguard_version` (default `v0.14.1`)
- `foxguard_sha256` (default `""`) - sha256 of the release binary for the runner; required with any version other than `v0.14.1`, whose five binary digests (linux and macos on x86_64 and aarch64, windows on x86_64) are pinned in the action; with `v0.14.1` it may only repeat the pinned digest, a different one is refused

Requires `actions/checkout` with `fetch-depth: 0` on pull requests: the action reads the config from the base commit and refuses the scan when that commit is missing.

Outputs:

- `fg_bin`: path of the foxguard binary the action downloaded and verified.
  The action sets no environment variable for later steps; a step that runs
  the same binary reads this output.

Notes:

- The foxguard release binary is verified before it runs against a sha256
  held in this repository (or `foxguard_sha256`), never against a checksums
  file fetched from the same release; a mismatch or a missing digest fails
  the step. foxguard publishes no Windows arm64 binary; that runner is refused.

The Foxguard action exports no report, SARIF or artifact. `fail_on_findings: false`
is refused before scanning. Scanner errors and findings name Foxguard and the
branch, link https://nikolareljin.github.io/leak-lock/, and instruct the operator
to run Scan Repository and repository tests locally before pushing. No scanner
results, counts, rule ids, file paths or report paths are logged. The scan
runs with `--quiet` and writes its JSON report to a private temporary directory
that is removed before the step ends.

PR scans read configuration from the base commit (`config_path`, or
`.foxguard.yml` when present), so the checkout must hold it: use
`fetch-depth: 0`, as `foxguard-scan.yml` does; a missing base commit refuses
the scan. Other Git scans use `HEAD`, and a directory outside a work tree gets
an empty config. A config added by the pull request is
not read, a named `config_path` missing at the base refuses the scan, and a
config with a `baseline` key at any depth is refused. The config is parsed
with PyYAML, which the GitHub-hosted Ubuntu runners ship; a config that does
not parse, or a runner without PyYAML when a config exists, refuses the scan. The explicit config also stops
foxguard from discovering a `.foxguard.yml` planted in the scanned tree.
The vetted copy is written beside the caller's config, under a temporary
`.foxguard-reviewed-*.yml` name, and removed when the step ends. foxguard
resolves `scan.ignore_rules[].path` and `secrets.exclude_paths` against the
config's directory, so they match as they would in place. A config directory
that resolves outside the repository refuses the scan.

A scan that reads no file fails. The action refuses to run when its own
checkout lies under `scan_path`, where the library's scripts would be read as
the caller's; `foxguard-scan.yml` keeps the two checkouts side by side.

Example:

```yaml
- name: Foxguard scan
  uses: nikolareljin/ci-helpers/.github/actions/foxguard-scan@production
  with:
    scan_path: "."
    severity: medium
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
| `azure` | Paid | MSI + EXE Authenticode | Checks the credentials; with `export_env: "true"` also writes them to `GITHUB_ENV`. Signing is a separate `azure/trusted-signing-action` step |

Inputs:

| Input | Required for | Default | Description |
|-------|-------------|---------|-------------|
| `sign_mode` | all | - | `tauri_updater`, `pfx` or `azure`; anything else fails the step |
| `tauri_signing_private_key` | `tauri_updater` | — | Base64 or raw ED25519 private key |
| `tauri_signing_private_key_password` | no | `""` | Password for the updater key |
| `certificate_base64` | `pfx` | - | Base64 of the `.pfx` |
| `certificate_password` | `pfx` | - | PFX password |
| `timestamp_server` | no | `""` | RFC 3161 URL; empty uses `http://timestamp.digicert.com` |
| `files_folder` | no | `""` | `pfx`: folder to sign (recursive `.exe`, `.msi`; a symbolic link or junction in it is refused); empty only checks the PFX |
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
- `pfx` mode with `files_folder` needs a Windows runner. Run it in a job of
  its own that downloads the built installers and runs no build or app code,
  as `tauri-release`'s `sign-windows` job does: a build step runs the app's
  npm and cargo scripts, which can change files, `PATH` or `GITHUB_ENV` for
  every later step of the same job and so reach the certificate. The PFX is
  checked in memory, written to `RUNNER_TEMP` with an owner-only ACL for
  `signtool /f`, and deleted when the step ends, on failure too; nothing is
  imported into a certificate store. Publicly trusted certificates issued
  since 2023-06-01 have hardware-bound keys and cannot be exported to a
  `.pfx`; see [Windows signing](windows-signing.md).
- `azure` mode: the actual signing happens via `azure/trusted-signing-action`
  in a separate step, in the same kind of signing-only job. This action only
  checks the credentials.
- Generate a free updater key with: `cargo tauri signer generate -w ~/.tauri/myapp.key`

## pimcore-bundle-check

Path: `.github/actions/pimcore-bundle-check`

Purpose: Run PHPCS, PHPStan and PHPUnit for a Pimcore bundle inside a Docker
Compose stack, with an optional standalone (no-Docker) mode.

Note: Requires Docker on the runner and a compose file that mounts the bundle.
For most repositories the [`pimcore.yml` preset](presets.md#pimcore) is the
better entry point — it wraps this action and adds a PHP version matrix.

Inputs that end in `_command` are shell code and run as written. Every other input reaches docker as text and is never expanded or run.

Inputs (selected):

- `compose_file` (default `test/docker-compose.yml`)
- `bundle_src` (default `"."`), `bundle_src_env` (default `BUNDLE_SRC`)
- `php_service` (default `php`), `db_service` (default `db`), `db_wait_seconds` (default `"20"`)
- `out_dir` (default `test/tmp`)
- `php_version` (default `""`) — drives the optional standalone steps, and is exported for the Compose stack
- `php_version_env` (default `PHP_VERSION`) — variable `php_version` is exported as; `""` exports nothing
- `composer_command`, `phpcs_command`, `phpstan_command`, `phpunit_command`, `phpunit_coverage_command` (run inside the `php` service)
- `php_lint_command`, `phpcs_standalone_command`, `phpunit_standalone_command` (default `""`, run on the runner without Docker), `phpunit_working_directory` (default `"."`)
- `fail_on_findings` (default `"true"`), `cleanup` (default `"true"`)

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

For a whole job, with a generated stack and a version matrix, use the
[`wp-plugin-check.yml`](workflows.md#wp-plugin-checkyml) workflow instead.

Inputs that end in `_command` are shell code and run as written. Every other input reaches docker and `wp` as text and is never expanded or run.

Inputs:

- `compose_file` (default `test/docker-compose.yml`)
- `plugin_slug` (required)
- `plugin_src` (default `"."`)
- `plugin_src_env` (default `PLUGIN_SRC`) - the variable the compose file mounts the plugin from
- `wpcli_service` (default `wpcli`), `db_service` (default `db`), `wordpress_service` (default `wordpress`) - compose service names
- `host_port` (default `"8080"`) - host port of the WordPress service
- `db_wait_seconds` (default `"30"`)
- `multisite` (default `"true"`), `activate_network` (default `"true"`)
- `admin_user` (default `admin`), `admin_password` (default `""`: a random password per run), `admin_email` (default `admin@example.com`), `site_title` (default `WP Test Site`)
- `meta_check_script` (default `""`) - a `wp eval-file` script for your own checks
- `out_dir` (default `test/tmp`)
- `php_version` (optional for lint/PHPUnit)
- `php_lint_command` (optional, errors only)
- `phpcs_warning_command` (optional, non-blocking)
- `phpunit_command` (optional, standalone), `phpunit_working_directory` (default `"."`)
- `fail_on_findings` (default `"false"`)
- `cleanup` (default `"true"`) - run `docker compose down` afterwards

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

## publication-guard

The publication guard installs job-wide outbound Git checks from the trusted
workflow revision. Writer jobs run it before publishing. It refuses sensitive
content and scanner results before Git sends objects, even in secondary clones.
Missing checkers or tools refuse publication. GitHub receives only a verdict;
detailed diagnostics must be reproduced and examined locally.

## publication-check

Checks artifact and release files before an upload action runs. The reusable
workflows check out this action at the workflow revision, validate the selected
files and pass private snapshots to the uploader. A failed check stops uploads,
including steps with `always()` or `failure()`.

| Input | Default | Purpose |
| --- | --- | --- |
| `mode` | required | `artifact` or `release` pattern semantics |
| `paths` | empty | Original uploader patterns, including artifact exclusions |
| `metadata` | empty | Artifact name, release name, tag and target commit |
| `include_hidden_files` | `false` | Include hidden artifact files |
| `working_directory` | empty | Base directory for release patterns |
| `body_path` | empty | Release notes file |
| `fail_on_unmatched_files` | `false` | Refuse unmatched release patterns |

Outputs `paths` and `body_path` refer only to validated snapshots outside the
workspace. Post-job cleanup removes them. Files above 64 MiB, more than 2,000
selected files, Git metadata and colliding published names fail closed. Runner
temporary paths containing uploader pattern characters are refused. Archives
use the shared checker's size and nesting limits. Release notes are checked
before publication; server-generated notes are fetched and checked first.

CI prints only the failing tool and safe branch instructions with
https://nikolareljin.github.io/leak-lock/. Inspect findings locally. This action
checks the workflows' standard upload steps. An exclusive publication writer is
still required to prevent deliberate client or credential bypasses.

PII checks also apply to public author contact annotations in vendored files.
Packaging self-tests build and inspect those packages locally without uploading
them. Private diagnostic markers remain blocked after copying or renaming.

# Changelog

## Unreleased

### Added

- **`auto-tag-release.yml`:** New `release_workflow` input (default `""`). When set to a workflow
  filename (e.g. `"release.yml"`), the workflow is dispatched via `workflow_dispatch` after the
  version tag is pushed, with `release_tag` set to the detected version. This bypasses the GitHub
  restriction that prevents `GITHUB_TOKEN`-created tags from firing tag-push triggered workflows.
  Callers must also grant `actions: write` permission. The workflow filename is validated against
  a safe-characters regex before use.

### Changed

- **`create_production.sh`:** Post-push verification now hard-fails when either the `production`
  tag or branch on the remote is missing or points to a different commit than expected. Previously
  the script would exit on push failure (via `set -euo pipefail`) but did not explicitly confirm
  that both remote refs converged to the same SHA. Annotated release tags are handled correctly
  via the peeled `^{}` entry from `git ls-remote`.

## 2026-06-09 — 0.12.0

### Added

- **`fpc-release.yml`:** New reusable workflow for Free Pascal (FPC) projects. Builds a binary
  natively on Linux (`ubuntu-latest`), macOS ARM64 (`macos-latest`), macOS x86_64 (`macos-13`),
  and Windows (`windows-latest`) using the platform FPC package manager (apt / Homebrew /
  Chocolatey), packages each into a release archive (`.tar.gz` on Linux/macOS, `.zip` on
  Windows), and optionally uploads all four to a GitHub release. Supports bundling runtime data
  files (`data_glob`) and extra docs (`extra_files`) alongside the binary.
  Additional Linux package formats (`linux_packages: "deb,rpm,appimage"`) and macOS DMG
  (`macos_dmg: "true"`) can be enabled with package metadata inputs (`package_maintainer`,
  `package_description`, `package_url`, `app_icon`).

## 2026-06-04 — 0.11.0

### Added

- **`php.yml`:** New `node_version` input (default `""`) — set to e.g. `"22"` to install Node.js for npm-based build steps alongside PHP.

### Changed

- **Runtime defaults bumped to current supported versions:**
  - PHP: `8.2` → `8.4` (`php.yml`, `php-scan.yml`, `pimcore.yml`)
  - Go: `1.22` → `1.24` (`go.yml`, `go-scan.yml`, `go-release.yml`, `go-deploy.yml`)
  - Python: `3.12` → `3.13` (`python.yml`, `python-scan.yml`)
  - Node.js: `20` → `22` (`node.yml`, `react.yml`, `node-scan.yml`, `react-scan.yml`, `vue-scan.yml`, `playwright.yml`, `cypress.yml`)
- **Security tool SHA updates** (resolves dependabot PRs #69–#73):
  - `aquasecurity/trivy-action`: `314ff8b` → `bfa4b33` (all reusable workflows + composite action)
  - `snyk/actions/docker`: `9cf6ca7` → `8e119fb`
  - `securego/gosec`: `6351b0c` → `92ed8df`
  - `docker/setup-qemu-action`: `ce36039` (v4.0.0) → `06116385` (v4.1.0)
  - `actions/upload-artifact`: v4 → v7
  - `actions/download-artifact`: v4 → v8

## 2026-05-29 — 0.10.6

### Fixed

- **`deb-build.yml`:** `extra_packages` is now split into an array before being passed to `apt-get`, preventing shell metacharacter injection from crafted values.
- **`deb-build.yml`:** `upload_to_release` input is now validated early; any value other than `auto`, `true`, or `false` fails with a clear error instead of silently publishing.
- **`deb-build.yml`:** `release_tag` newlines/CR stripped before writing to `$GITHUB_OUTPUT` to prevent output injection.
- **`deb-build.yml`:** SHA-pinned `softprops/action-gh-release` ref now includes the required `# v3 @ YYYY-MM-DD` annotation so `update_pinned_actions.sh` can track and refresh it.
- **`rust-release-tarballs.yml`:** Both tag-resolve steps now strip newlines/CR from `release_tag` before writing to `$GITHUB_OUTPUT` (injection hardening) and now accept `vX.Y.Z` tags in addition to `X.Y.Z`.
- **`rust-release-tarballs.yml`:** Homebrew formula `test` block now correctly produces `#{bin}/…` Ruby interpolation (was `\#{bin}/…` which rendered as a literal string and broke `brew test`).
- **`rust-release-tarballs.yml`:** SHA-pinned `softprops/action-gh-release` refs now include the required `# v3 @ YYYY-MM-DD` annotation.
- **`rust-release-tarballs.yml`:** `homepage` input description clarified — must be a GitHub repo URL; used as the base for release download URLs.

## 2026-05-29 — 0.10.5

### Added

- **`deb-build.yml`:** New `upload_to_release` input (`auto` / `true` / `false`, default: `auto`) — when `auto`, uploads the built `.deb` to the GitHub release whenever triggered by a version tag or when `release_tag` is provided.
- **`deb-build.yml`:** New `release_tag` input for manual backfill via `workflow_dispatch` (e.g. re-running a release after a tag was created without triggering CI).

### Fixed

- **`deb-build.yml`:** `extra_packages`, `prebuild_command`, and `build_command` inputs are now passed via env vars in `run:` steps rather than inline `${{ }}` interpolation, eliminating potential shell injection risk.

## 2026-05-26 — 0.10.4

### Fixed

- **`flutter-release.yml`:** Android signing secrets are no longer required when
  `build_android: true` without `deploy_google_play: true`. Missing secrets now emit
  a workflow warning and skip `key.properties` setup, allowing projects that use their
  own default signing config (e.g. debug signing) to run CI builds without providing
  keystore credentials. Signing secrets remain mandatory when `deploy_google_play: true`.

## 2026-05-25 — 0.10.3

### Changed

- **`docker-multiarch.yml`:** Bump `docker/setup-qemu-action` v3 → v4.0.0,
  `docker/setup-buildx-action` v3 → v4.1.0, `docker/login-action` v3 → v4.2.0,
  `docker/build-push-action` v6 → v7.2.0 (all SHA-pinned).
- **`tauri-release.yml`:** Bump `azure/trusted-signing-action` v0 → v2.0.0 and
  `actions/download-artifact` v4 → v8.0.1 (SHA-pinned).
- **`go-release.yml`:** Bump `softprops/action-gh-release` v1 → v3 (SHA-pinned).

## 2026-05-23 — 0.10.2

### Fixed

- **`reusable workflows`:** Replace all `./` relative action refs with full repo
  paths to fix resolution in caller repositories (#52).
- **`ci.yml` / misc:** Pin `actions/github-script` to SHA `3a2844b7` (v9) (#51).

## 2026-05-23 — 0.10.1

### Fixed

- **`reusable workflows`:** Use full repo ref for gitleaks composite action call
  inside reusable workflows (#50).

## 2026-05-23 — 0.10.0

### Added

- **`tauri-scan.yml`:** Fast Tauri CI check for Linux (ubuntu-22.04). Installs
  WebKit2GTK 4.1 system dependencies, sets up Rust via `dtolnay/rust-toolchain`,
  runs `cargo fmt -- --check`, `cargo clippy -- -D warnings`, and `cargo check`
  (no full build — keeps the gate fast). Optional Node + frontend install for
  front-end type-checking. All commands routed through `env:` variables to prevent
  expression injection from workflow inputs (protects against crafted ref names
  or other GitHub context values being interpolated directly into `run:` scripts).

- **`tauri.yml`:** Standalone Tauri CI preset (does not wrap `ci.yml` — `ci.yml`
  has no `apt` step). Runs full `cargo test` + `cargo build` on ubuntu-22.04 with
  WebKit2GTK dependencies. Optional Node setup and frontend build before Cargo steps.

- **`tauri-release.yml`:** Cross-platform Tauri desktop release workflow. Builds on
  a 3-job matrix: `macos-latest` (universal binary via `aarch64 + x86_64`, requires
  both rustup targets), `windows-latest` (MSI + NSIS), `ubuntu-22.04` (AppImage +
  deb + rpm). macOS job uses the new `actions/macos-sign` composite action for
  keychain import and optional `xcrun notarytool submit --wait` + `xcrun stapler
  staple` notarization. Windows job uses the new `actions/windows-sign` composite
  action in one of three modes (see below). Release job downloads all artifacts and
  uploads via `softprops/action-gh-release`. Optional dist-repo cross-publish and
  WinGet submission job via `winget-submit.yml`.

- **`winget-submit.yml`:** Standalone reusable workflow for submitting Windows
  Package Manager manifests to a fork of `microsoft/winget-pkgs`. Installs
  `wingetcreate` via `dotnet tool install --global Microsoft.WingetCreator` and runs
  `wingetcreate update --submit`. URL format: `<installer_url>|<arch>|<type>`
  (e.g. `...setup.exe|x64|nullsoft`). Inputs: `package_id`, `version`,
  `installer_url`, `installer_arch`, `installer_type`, `release_notes_url`,
  `winget_fork_owner`. Secret: `WINGET_PKGS_TOKEN`.

- **`docker-multiarch.yml`:** Multi-architecture Docker buildx workflow (build +
  push). Sets up QEMU and buildx, logs in to a configurable registry (default
  `ghcr.io`), pushes versioned tag plus optional `:latest`. Optional post-build
  Trivy image scan. Inputs: `image_name`, `tag`, `platforms`, `dockerfile`,
  `context`, `build_args`, `push_latest`, `registry`, `registry_username`,
  `scan_after_build`, `trivy_severity`, `fail_on_scan_findings`.
  Secret: `registry_token`. Outputs: `image_digest`, `image_ref`.

- **`manifest-version.yml`:** Generic manifest version reader, git tagger, and
  workflow dispatcher. Extracts version from `package.json`, `Cargo.toml`,
  `pubspec.yaml`, `pyproject.toml`, a plain `VERSION` file, or a custom shell
  command. Validates semver format, optionally skips if tag already exists, creates
  a lightweight git tag, and dispatches named workflows via `gh workflow run` with
  support for extra inputs via `dispatch_inputs_json`. Outputs: `version`, `tag`,
  `skipped`.

- **`actions/macos-sign`:** Composite action for macOS codesigning setup. Imports
  an Apple p12 certificate into a temporary keychain (`ci-build.keychain-db`), sets
  the keychain search list and `apple-tool:,apple:,codesign:` partition access, and
  exports all Apple env vars (`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_PASSWORD`) to
  `$GITHUB_ENV` for Tauri. Keychain cleanup is the caller's responsibility —
  composite actions have no post-run hook; `tauri-release.yml` includes the
  required `if: always()` cleanup step; custom callers must add their own.

- **`actions/windows-sign`:** Composite action for Windows codesigning with three
  modes:
  - `tauri_updater` (free): exports `TAURI_SIGNING_PRIVATE_KEY` and
    `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` for Tauri's ED25519 updater bundle signing.
    Signs `.sig` files only — does not sign the MSI/EXE binary.
  - `pfx` (paid OV/EV): decodes a base64 PFX, imports it to `Cert:\CurrentUser\My`,
    extracts the thumbprint, and sets `TAURI_WINDOWS_SIGN_COMMAND` (signtool with
    RFC 3161 timestamp via Sectigo) and `WINDOWS_CERT_THUMBPRINT`. Signs MSI + EXE
    with Authenticode. PFX/cert cleanup is the caller's responsibility (same
    composite-action post-run limitation); `tauri-release.yml` includes the step.
  - `azure` (paid Azure Trusted Signing): exports Azure credentials to `$GITHUB_ENV`
    for consumption by `azure/trusted-signing-action` in a subsequent post-build
    step. Uses `azuresigntool` internally — not compatible with
    `TAURI_WINDOWS_SIGN_COMMAND`.

## 2026-05-23 — 0.9.3

### Fixed
- **`auto-tag-release.yml` squash-merge detection:** Added a second commit-subject
  fallback that extracts `(#N)` from squash-merge subjects and validates the PR
  directly via `pulls.get`. The association-index path (`listPullRequestsAssociatedWithCommit`)
  is eventually-consistent and could silently miss a release merge fired seconds after
  the push; `pulls.get` is not subject to that delay. Re-runnable warning emitted
  when `merge_commit_sha` mismatch is detected (delayed indexing edge case).
- **`create_production.sh` branch drift:** Script now also force-pushes the
  production BRANCH to the same commit as the production TAG after every release.
  Previously only the tag was moved, leaving `refs/heads/production` stale and
  causing GitHub Actions to resolve `@production` to the old branch commit instead
  of the new tag commit. Pass `--no-branch` to opt out of the branch update.

## 2026-05-22 — 0.9.2

### Changed
- Refreshed stale pinned GitHub Action SHAs required by the production-tag
  security gate.

## 2026-05-22 — 0.9.0

### Added
- **`data-safety-scan` composite action:** Centralized JSON data scanning that
  rejects sensitive-key fields before application data is shipped.

## 2026-05-21 — 0.8.0

### Added
- **`install_command` input for `pr-gate.yml`:** New optional input that runs a
  dedicated Install step before Lint/Test/Build. Allows callers to install
  dependencies once and reuse them across subsequent steps, eliminating
  redundant `npm ci` / `pip install` calls that previously appeared in both
  `lint_command` and `test_command`.
- **`docs/private-repo-ci-strategy.md`:** Full 3-layer CI model documentation
  (Local hooks → PR gate → Main gate) with per-stack workflow examples for
  Node/TypeScript, Python, Go, Rust, Flutter, Java/Gradle, and PHP. Includes
  a table of repos that need the duplicate-trigger fix and a reference to the
  script-helpers local test scripts.

## 2026-05-14 — 0.7.3

### Changed
- **Node.js 24 opt-in:** Added `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` workflow-level
  env to all workflows that invoke third-party actions still on Node 20 runtime
  (`auto-tag-release.yml`, `gitleaks-scan.yml`, `release-rc-pr.yml`,
  `release-tag-gate.yml`, `flutter-release.yml`, `go-release.yml`,
  `rust-release.yml`, `release-build.yml`, `pr-gate.yml`, `ci.yml`).
  Silences Node 20 deprecation warnings ahead of the forced migration on
  June 2, 2026 (Node 20 removed from runners September 16, 2026).

## 2026-04-13 — 0.7.2

### Changed
- **Node.js runtime:** Upgraded `actions/setup-node` from `v4` to `v5` across all
  Node-using workflows (`ci.yml`, `deploy.yml`, `pr-gate.yml`, `react-scan.yml`,
  `release-build.yml`, `node-scan.yml`, `vue-scan.yml`). Default `node_version`
  updated from `"20"` to `"22"` (Active LTS) in `node.yml`, `node-scan.yml`,
  `react.yml`, `react-scan.yml`, `vue-scan.yml`, `cypress.yml`, and
  `playwright.yml`. Node.js 20 GitHub Actions runtime is deprecated; forced
  migration to Node.js 24 begins June 2, 2026.

### Added
- **`scripts/update_pinned_actions.sh`:** Local helper script that scans `.github/` for
  SHA-pinned action refs annotated with `# <ref> @ <date>`, fetches the current HEAD SHA
  from the GitHub API (with caching for repeated repo+ref queries), and updates stale pins
  in place. Supports `--check` (dry-run / CI gate) and `--dir <path>` override. Run with
  `gh` CLI authenticated.

### Security
- **Supply chain:** Pinned three floating `@master` action refs to reviewed commit SHAs:
  `securego/gosec` in `go-scan.yml`, `aquasecurity/trivy-action` and `snyk/actions/docker` in `docker-scan.yml`.
  Floating refs allow upstream changes to silently alter CI behaviour.
- **Pinned** `softprops/action-gh-release@v1` to its SHA in `go-release.yml`.
- **Expression injection (defence in depth):** Moved non-command workflow inputs
  (`ldflags`, paths, names, WP-CLI args) from direct `${{ inputs.* }}` interpolation
  in `run:` blocks to `env:` variables in `go-deploy.yml`, `go-release.yml`, and
  `php-scan.yml`. Prevents shell-level injection if a caller ever passes user-controlled
  content as a non-command input.
- **SSH_OPTS quoting:** Changed `SSH_OPTS` in `go-deploy.yml` from an unquoted string
  (used in `ssh $SSH_OPTS`) to a proper bash array (`SSH_OPTS=(...)`, `"${SSH_OPTS[@]}"`)
  to prevent word-splitting on the key path.
- **Explicit permissions:** Added `permissions: contents: read` to `gitleaks-check.yml`
  and `release-tag-check.yml`; added `pull-requests: read` to `gitleaks-check.yml`.
  These non-reusable workflows previously relied on the repo's `GITHUB_TOKEN` default.
- **`version_bump.sh`:** Switched to `rg -F` for literal match discovery and Perl
  literal replacements so version strings containing `/` and other special characters
  are handled safely during in-place updates.
- **`rust_release_build.sh`:** Added allowlist validation for the `--apt-packages`
  argument before passing it to `apt-get install` to prevent command injection via
  crafted package name strings.

## 2026-04-11

### Fixed
- Reworked reusable workflows that previously depended on caller-local `.github/actions/*` paths to use shared `script-helpers` scripts or direct third-party actions instead, so downstream callers can use them safely.

### Changed
- `gitleaks-scan.yml`: `scan_path`, `report_format`, and `config_path` inputs now fail fast with a clear error when provided with non-default values. Previously the workflow delegated to the local composite action which would warn and proceed; the new direct `gitleaks-action` integration cannot honour these overrides, so non-default values are rejected explicitly. Input descriptions document this contract.
- `auto-tag-release.yml`: added `update_production_tag` boolean input (default `true`). When set to `false`, the Bootstrap script-helpers and Update production tag steps are skipped, allowing external callers that do not carry a floating `production` tag to use this reusable workflow safely.

## 2026-04-07

### Added
- Added `pimcore-bundle-check.yml` reusable workflow and matching composite action
  `.github/actions/pimcore-bundle-check/action.yml` for Docker-based Pimcore 11
  bundle testing (PHPUnit, PHPCS PSR-12, PHPStan, coverage). Mirrors the existing
  `wp-plugin-check` pattern: Docker Compose orchestrates a `php` + `db` (MySQL 8)
  stack; tests run inside the container via `docker compose exec`.
- Added `pimcore.yml` preset that wraps `pimcore-bundle-check.yml` with Pimcore 11
  defaults (PHP 8.1, PSR-12 PHPCS, PHPUnit). Minimal one-liner usage:
  `uses: nikolareljin/ci-helpers/.github/workflows/pimcore.yml@production`
- Added Pimcore framework detection to `php-scan.yml`: auto-detects bundles via
  `"type": "pimcore-bundle"` in `composer.json` or a `pimcore/pimcore` dependency,
  and conditionally runs `lint_pimcore_command` (default: PSR-12 PHPCS on `src/`).

## 2026-03-30

### Fixed
- Updated `scripts/create_production.sh` to push the movable `production` tag with `--force` because Git rejects `--force-with-lease` for existing tag refs even after a fresh tag fetch.

## 2026-03-26

### Added
- Added `scripts/check_release_version.sh` plus a tracked `.githooks/pre-commit` hook to enforce that `VERSION` matches `release/[v]X.Y.Z[-rcN]` or `release/[v]X.Y.Z[-rc.N]` branch names during local commits.

### Changed
- `release-tag-check.yml` now runs on both branch creation and pushes for `release/*` branches and validates `VERSION` before checking tag availability.

## 2026-03-24

### Fixed
- Hardened `auto-tag-release.yml` so merged release branches still tag correctly when GitHub has not yet associated the merge commit with its PR, using a merge-subject fallback that validates the referenced PR plus default-branch and `merge_commit_sha` guards.

## 2026-03-20

### Changed
- Reverted repo-internal reusable workflow and composite action wrappers back to local `./.github/...` references so `ci-helpers` validates the current branch instead of self-referencing `@production`.
- Updated reusable and preset GitHub workflows from `actions/checkout@v4` to `actions/checkout@v5` and from `actions/setup-python@v5` to `actions/setup-python@v6` to stay aligned with GitHub's Node 24 runtime transition.
- Restored local `./.github/...` references inside ci-helpers' own reusable workflows and composite-action callers so the repo no longer imports itself via `nikolareljin/ci-helpers@production`.

## 2026-03-19

### Changed
- Added `flutter_version` and `flutter_channel` inputs to the generic reusable `ci.yml` and `release-build.yml` workflows.
- Added `lint_command` and `test_command` support to `release-build.yml` so release artifact jobs can reuse the same validation flow before publishing.
- Updated workflow and usage docs with Flutter APK and pre-build validation examples.

## 2026-01-29

### Changed
- Added a macOS runner guard for App Store deploy preparation in the Flutter release workflow.
- Updated App Store Connect key encoding instructions with Linux-friendly examples.
- Documented a macOS runner example for iOS/App Store deployments in flutter-release workflow docs.

## 2026-01-28

### Added
- Added a reusable `go-deploy.yml` workflow for building and deploying Go binaries to remote servers via SSH/rsync.
- Documented go-deploy workflow inputs, secrets, and usage examples.

## 2026-01-19

### Added
- Added a reusable Flutter release workflow for building Android/iOS and deploying via Fastlane.
- Documented Flutter release workflow inputs and added an example.
- Added a `release-rc-pr.yml` workflow to automatically open pull requests for release-candidate branches.
- Added `SECURITY.md` with security reporting and support policy details.
- Added `APPLE_FASTLANE_PUBLISH.md` and `GOOGLE_PLAY_PUBLISH.md` guides documenting app store publishing via Fastlane.

## 2026-01-07 (0.4.0)

### Changed
- Vendored new script-helpers package publishing helpers and updated workflows to use them.
- Added reusable RPM build and Homebrew packaging workflows with optional publish support.

## 2026-01-06

### Changed
- Moved PPA upload helper to vendored script-helpers and updated workflows to use it.

## 2026-01-05

### Added
- Added a reusable Debian package build workflow that uploads artifacts.

## 2026-01-04

### Added
- Added a reusable workflow to build and publish Debian source packages to Launchpad PPAs.
- Documented PPA publish inputs and required secrets.

## 2026-01-03 (0.3.0)

### Changed
- Updated docs to consistently point reusable workflow/action references at @production.
- Bumped production tag references to 0.3.0 in documentation.

## 2025-12-31 (0.2.0)

### Added
- Added a release-notes composite action with optional binary links.
- Added a generic release-build reusable workflow for publishing release artifacts.
- Added a Rust multi-target release workflow and rust release build helper script.
- Added a Go multi-target release workflow.
- Added a production branch update script and repo-local workflow.

### Changed
- Updated docs with release workflows, release notes usage, and install-from-git examples.

## 2025-12-27 (0.1.2)

### Added
- Added lint defaults across language presets and scan workflows (Python, C#, Java, Go, Rust, PHP, Node, React).
- Added release tag PR gate workflow and an auto-tag push wrapper for repo-local usage.
- Documented release tag gate + auto-tag setup for external repos.

### Changed
- Python defaults now install pytest before running tests and support pyproject-only installs (with pyinstaller).
- Node/React/C#/Go/Rust defaults now fetch dependencies before running tests.
- Auto-tag release workflow is now reusable, default-branch aware, and hard-fails if the tag already exists.
- Release branch tag guard now accepts `release/X.Y.Z-rcN` branches.
- Updated docs and references to version 0.1.2.

## 2025-12-26 (0.1.1)

### Added
- Documented VERSION as the source of truth for the production tag in README, docs, and AGENTS.
- Added `scripts/version_bump.sh` to bump VERSION and update @vX.Y.Z references.

### Changed
- Moved preset workflows to the top-level `.github/workflows/` directory to satisfy reusable workflow requirements.
- Updated the Gitleaks composite action defaults to SARIF (`results.sarif`) to match `gitleaks-action` output and avoid missing report files.
- Added optional artifact upload support to the Gitleaks composite action and updated docs/examples.
- Standardized script headers and help output for all scripts in `scripts/`.

### Added
- Added a release-branch guard workflow that checks for existing tags when `release/*` branches are created.

## 2025-12-25

### Added
- Gitleaks-based leak scanning workflow, composite action, and PR/cron check.
- Reusable scan workflows for PHP, Python, Go, Rust, Java, C#, Node, React, Vue, and Docker.
- Usage guide plus expanded examples for workflows and composite actions.

### Changed
- Replaced NoseyParker scan docs and references with Gitleaks.
- Gitleaks reports now include Leak-Lock extension links when leaks are found.
- PR and auto-tag examples now include `master` alongside `main`.

## 2025-12-23 (0.1.0)

### Added
- Initial reusable workflows, presets, and composite actions for CI and scans.
- Playwright/Cypress/E2E support with Yarn and start-server-and-test defaults.
- Vendored script-helpers with sync automation.

### Changed
- README and docs expanded with quick start, examples, and links.
- License and repository naming updates.

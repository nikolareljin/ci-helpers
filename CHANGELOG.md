# Changelog

## 2026-04-13 — 0.7.2

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

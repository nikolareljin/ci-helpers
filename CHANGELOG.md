# Changelog

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

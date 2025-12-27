# Changelog

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

## 2025-12-26

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

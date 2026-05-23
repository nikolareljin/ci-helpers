# Documentation

This directory contains detailed guidance for using and extending the reusable
workflows and composite actions in this repository.

Current production tag: 0.10.0 (from VERSION).

Start here:
- [Reusable workflows](workflows.md) — CI, PR gate, deploy, scan, release, Tauri, WinGet, Docker multi-arch, manifest versioning, and release-rc-pr.
- [Presets](presets.md) — stack-specific presets (Java/Gradle/Kotlin/Rust/Node/React/Playwright/Cypress).
- [Composite actions](actions.md) — semver compare, release tag guard, release notes, scan helpers, macOS signing, Windows signing.
- [Examples](examples.md) — common usage patterns (monorepos, E2E servers, Docker + E2E).
- [Usage guide](usage.md) — consuming workflows and actions from other repos, plus automation for the `production` tag (not a branch).
- Local release safety hook: configure `git config core.hooksPath .githooks` to enable the tracked pre-commit guard that verifies `VERSION` matches `release/[v]X.Y.Z[-rcN]` or `release/[v]X.Y.Z[-rc.N]`.
- [Release RC PR workflow](RELEASE_RC_PR.md) — auto-opening PRs from release candidate branches; also a reusable `workflow_call` workflow for caller repos.
- [Apple App Store publishing](APPLE_FASTLANE_PUBLISH.md) — Fastlane + GitHub Actions guidance.
- [Google Play publishing](GOOGLE_PLAY_PUBLISH.md) — Fastlane + GitHub Actions guidance.
- [Security best practices](SECURITY.md) — CI secret handling.

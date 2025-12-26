# Repository Guidelines

## Project Structure & Module Organization

- `.github/workflows/`: reusable workflows (`ci.yml`, `pr-gate.yml`, `deploy.yml`) and top-level preset workflows (for GitHub reusable workflow requirements).
- `.github/actions/`: composite actions (`semver-compare`, `check-release-tag`).
- `scripts/`: Bash helpers used by actions and maintenance tasks.
- `vendor/script-helpers/`: vendored Bash utilities (sync with `scripts/sync_script_helpers.sh`).
- `docs/`: detailed usage docs and examples.

## Build, Test, and Development Commands

- `make examples`: runs safe, non-interactive demos in `scripts/example_*.sh`.
- `RUN_INTERACTIVE=1 make examples`: includes dialog-based prompts.
- `RUN_NETWORK=1 make examples`: enables download demo for network paths.
- `shellcheck lib/*.sh scripts/*.sh`: lint Bash scripts (add suppressions inline only when justified).

## Coding Style & Naming Conventions

- Bash scripts should assume `set -euo pipefail` in callers.
- Use two-space indents, snake_case functions, and lowercase filenames.
- Keep modules small, dependency-light, and named after their feature (`logging.sh`).
- Guard optional dependencies with `command -v` (Docker, dialog, etc.).

## Versioning

- Current production tag: v0.1.1 (from VERSION).
- `VERSION` is the source of truth; keep docs/examples `@vX.Y.Z` references in sync.
- Use `scripts/version_bump.sh major|minor|patch` to bump and update documentation/examples.

## Testing Guidelines

- Bash examples in `scripts/` serve as regression coverage; add a demo when behavior changes.
- Keep interactive or network demos opt-in via `RUN_INTERACTIVE`/`RUN_NETWORK`.
- Run `make examples` and `shellcheck` before PRs; note skipped paths in the PR.

## Commit & Pull Request Guidelines

- Use Conventional-style prefixes (`feat:`, `fix:`, `docs:`) with concise summaries.
- PRs should include: overview, test commands with outputs, notes on interactive/manual steps,
  and links to related issues. Update `CHANGELOG.md`/`RELEASE_CHECKLIST.md` when behavior or
  release steps change.

## Documentation

- Update `docs/` when adding new presets, inputs, or behaviors.
- Keep README examples aligned with workflow inputs and default order (E2E runs after Docker).

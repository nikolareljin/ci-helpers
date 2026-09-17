# Repository Guidelines

## Project Structure & Module Organization

- `.github/workflows/`: reusable workflows (`ci.yml`, `pr-gate.yml`, `deploy.yml`) and top-level preset workflows (for GitHub reusable workflow requirements).
- `.github/actions/`: composite actions (`semver-compare`, `check-release-tag`).
- `scripts/`: Bash helpers used by actions and maintenance tasks.
- `vendor/script-helpers/`: vendored Bash utilities. Sync with
  `scripts/sync_script_helpers.sh`, then prove it with `scripts/verify_vendor.sh`,
  then stage with `git add -f vendor/` (the directory is gitignored, so a plain
  `git add` silently skips new files). Upstream's `.github/` is deliberately not
  vendored. Update this whenever script-helpers cuts a release.
- `docs/`: detailed usage docs and examples.

## Build, Test, and Development Commands

- `bash scripts/docs_site.sh check`: runs safe, non-interactive demos in `scripts/example_*.sh`.
- `RUN_INTERACTIVE=1 bash scripts/docs_site.sh check`: includes dialog-based prompts.
- `RUN_NETWORK=1 bash scripts/docs_site.sh check`: enables download demo for network paths.
- `shellcheck lib/*.sh scripts/*.sh`: lint Bash scripts (add suppressions inline only when justified).

## Coding Style & Naming Conventions

- Bash scripts should assume `set -euo pipefail` in callers.
- Use two-space indents, snake_case functions, and lowercase filenames.
- Keep modules small, dependency-light, and named after their feature (`logging.sh`).
- Guard optional dependencies with `command -v` (Docker, dialog, etc.).

## Versioning

- Current production tag should match `VERSION`; keep docs/examples `@X.Y.Z` references in sync.
- Follow semantic versioning for all releases.
- The required release path is: create/update `release/x.y.z` from `main` -> on that branch, update `VERSION` to `x.y.z` as the first release change -> merge that branch to `main` via PR -> GitHub auto-tags `main` with `x.y.z`.
- Release work, including `VERSION` bumps and release-specific changes, must be done on `release/x.y.z` branches, not directly on `main`.
- Changes must not be made directly on `main`; updates should land on `main` only via pull requests from topic or release branches unless the user explicitly asks otherwise.
- Use `scripts/version_bump.sh major|minor|patch` to bump and update documentation/examples.

## Testing Guidelines

- Bash examples in `scripts/` serve as regression coverage; add a demo when behavior changes.
- Keep interactive or network demos opt-in via `RUN_INTERACTIVE`/`RUN_NETWORK`.
- Run `bash scripts/docs_site.sh check` and `shellcheck` before PRs; note skipped paths in the PR.

## Commit & Pull Request Guidelines

- Use Conventional-style prefixes (`feat:`, `fix:`, `docs:`) with concise summaries.
- PRs should include: overview, test commands with outputs, notes on interactive/manual steps,
  and links to related issues. Update `CHANGELOG.md`/`RELEASE_CHECKLIST.md` when behavior or
  release steps change.

## Documentation

- Update `docs/` when adding new presets, inputs, or behaviors.
- Keep README examples aligned with workflow inputs and default order (E2E runs after Docker).

## Documentation site

The site is built from `docs/` in place by MkDocs Material. There is no second
copy of the content.

- `bash scripts/docs_site.sh serve` — live reload while writing.
- `bash scripts/docs_site.sh preview` — build, then serve the built output. Use
  this to check anything involving search: lunr fetches its index over HTTP, so
  a site opened from `file://` silently finds nothing.
- `bash scripts/docs_site.sh check` — `mkdocs build --strict` into a temp
  directory. Run it before opening a PR.

`--strict` is the link checker. A moved page, a dead anchor, or a `docs/*.md`
that no `nav:` entry points at all fail the build. **Adding a page to `docs/`
means adding it to `nav:` in `mkdocs.yml`.**

There is no Makefile in this repository, deliberately: every entry point here is
`bash scripts/*.sh`, which is how the workflows invoke them.

`docs/about.md` is hand-maintained and must never be generated. It lists public,
non-fork repositories only, and nothing outside this repository may be read at
build time.

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

- `python3 scripts/check_workflow_yaml.py`: parse every workflow and action.
- `bash scripts/check_floating_refs.sh`: reject `@master`/`@main`/`@latest`/`@stable`.
- `bash scripts/update_pinned_actions.sh --check`: every third-party action SHA-pinned.
- `bash scripts/docs_site.sh check`: build the documentation site with `--strict`.
- `shellcheck scripts/*.sh`: lint the Bash entry points.

There is no `Makefile` and no `lib/` in this repository; every entry point is
`bash scripts/*.sh`, which is how the workflows invoke them.

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

- There is no unit-test suite here. The gates are static: `actionlint` (which
  shellchecks every `run:` block at warning level), the YAML parse check, the
  floating-ref scan, and the SHA-pin audit.
- Run the four commands above before opening a PR; note anything skipped.

## Commit & Pull Request Guidelines

- Use Conventional-style prefixes (`feat:`, `fix:`, `docs:`) with concise summaries.
- PRs should include: overview, test commands with outputs, notes on interactive/manual steps,
  and links to related issues. Update `CHANGELOG.md` when behavior or release
  steps change.

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
  directory, then assert the built output contains nothing but web assets. Run
  it before opening a PR.

**CI does not run this script.** The workflows call `mkdocs build --strict`
directly, so a change that breaks `docs_site.sh` itself ships green. The site is
still gated; the convenience wrapper around it is not. Editing it does trigger
the docs workflows, because it is in their `paths:` filters — but that only
proves the site still builds, not that the script still works.

`--strict` is the link checker. A moved page, a dead anchor, or a `docs/*.md`
that no `nav:` entry points at all fail the build. **Adding a page to `docs/`
means adding it to `nav:` in `mkdocs.yml`.**

There is no Makefile in this repository, deliberately: every entry point here is
`bash scripts/*.sh`, which is how the workflows invoke them.

`docs/about.md` is hand-maintained and must never be generated. It lists public,
non-fork repositories only, and nothing outside this repository may be read at
build time.

## Bash version policy

Scripts here source the vendored `script-helpers`, so they inherit its floor:
**write for bash 3.2, which then also runs on 4 and 5.** No `mapfile`, no
associative arrays, no namerefs, no `${var^^}`, no `shopt -s globstar`; and no
GNU-only tool flags (`sed -i`/`-r`, `readlink -f`, `realpath`, `grep -P`,
`date -d`, `find -printf`, `xargs -r`, `base64 -w`, `md5sum`/`sha256sum`, and
`\s` or `\b` in a grep or sed pattern), because macOS ships BSD versions.

This applies to `run:` blocks in workflows too, wherever one might execute on a
macOS runner.

`actionlint` runs shellcheck over every `run:` block at warning level, which
catches a good deal of this — but **not** the version-specific parts. Those are
caught by the sibling library's `portability_test.sh`, which does not run here.
A green actionlint is not evidence that a script is portable.

The reasoning, the full list, and what to write instead of each construct:
<https://nikolareljin.github.io/script-helpers/bash-compatibility/>

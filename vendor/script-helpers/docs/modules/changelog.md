# changelog

CHANGELOG maintenance.

The header format is load-bearing, not a style preference: `ci-helpers` extracts
GitHub Release notes from `CHANGELOG.md` by finding the section for the tag being
released. Any other header shape and the release notes silently fall back to an
auto-generated commit list. The canonical form is:

```markdown
## 2026-07-28 — v0.19.0
```

`YYYY-MM-DD`, a space, an **em-dash**, a space, then the version with an optional
`v` prefix. `changelog_check_header` is what stops that from rotting.

Functions
---------

- `changelog_check_header <file>`
  - Purpose: Verify the newest release header conforms. An `## [Unreleased]` section at the top is allowed and skipped over.
  - Returns: 0 and the version on success; 2 for a missing file; 1 when the header does not conform, with the offending line and the expected shape printed. An ASCII hyphen where the format needs an em-dash is called out specifically, because it is the common near-miss.

- `changelog_extract <file> <version>`
  - Purpose: Print the body of the section for `version`, without its header, for use as release notes. The `v` prefix is optional on both sides.
  - Returns: 0 and the body; 2 for missing arguments or a missing file; 1 when there is no such section.

- `changelog_new_section <file> <version> [--date YYYY-MM-DD] [--section <name>]...`
  - Purpose: Insert a new release section at the top, above the newest existing one and below any `## [Unreleased]` placeholder. Creates the file with a title when it does not exist.
  - Args:
    - `--date` — defaults to today, UTC.
    - `--section` — repeatable. Defaults to `Added`, `Changed`, `Fixed`, `Security`.
  - Returns: 0 on success, including when a section for that version already exists — it refuses to run twice, so it is safe in a release script that gets rerun. 2 for a non-semver version; 1 when the rewrite would produce an empty file.

Environment
-----------

No environment variables are required.

Dependencies
------------

None beyond coreutils.

Examples
--------

```bash
shlib_import changelog

changelog_check_header CHANGELOG.md || exit 1
changelog_new_section CHANGELOG.md 1.4.0
notes="$(changelog_extract CHANGELOG.md 1.4.0)"
```

PowerShell
----------

`ps/lib/changelog.ps1` mirrors this module with the same function names, and
returns `$null` where the Bash functions return a non-zero status.

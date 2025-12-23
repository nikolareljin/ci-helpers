# version

Semantic version helpers.

Functions
---------

- version_bump bump_type [-f VERSION_FILE]
  - Purpose: Increment the semantic version stored in a file.
  - Args:
    - bump_type — `major` | `minor` | `patch`.
    - `-f`, `--file` — path to the version file; defaults to `VERSION` at the project root (falls back to CWD).
  - Behavior:
    - Creates the file with `0.1.0` when missing.
    - Preserves a leading `v`/`V` prefix and any suffix after the first `-` when writing the bumped value.
  - Returns: 0 on success; non-zero on invalid input or write errors.
  - Dependencies: logging for output; uses `env::get_project_root` when available to resolve the default path.

- version_compare version_a version_b
  - Purpose: Compare two versions shaped like `[v]X.Y.Z[-suffix]` using numeric segments.
  - Behavior: Ignores a leading `v`/`V` and anything after the first `-` (e.g., `-rc1`).
  - Returns (exit codes; note that `-1` is reported as `255` in shells):
    - `-1` (exit status `255`) when `version_a` is lower than `version_b`.
    - `0` when equal.
    - `1` when `version_a` is greater than `version_b`.
    - `2` on missing args; `3` on invalid version format.
  - Notes: Supports multi-digit segments (e.g., `1.14.100`).

Examples
--------

```bash
shlib_import logging env version

# Bump the minor version in ./VERSION (relative to project root)
version_bump minor

# Compare versions
version_compare "v1.10.0-rc1" "1.9.9"
case $? in
  0) echo "Same";;
  1) echo "Left is newer";;
  255) echo "Left is older";;  # exit status 255 encodes -1
  2) echo "Missing args";;
  3) echo "Invalid input";;
esac
```

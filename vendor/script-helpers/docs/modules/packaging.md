# packaging

Helpers for packaging template rendering and dependency formatting.

## Example

```
source ./helpers.sh
shlib_import logging packaging

pkg_load_metadata packaging/packaging.env
pkg_join_list "$DEB_DEPENDS" ", "
```

## Functions

### `pkg_load_metadata`

Usage: `pkg_load_metadata <file>`

Loads packaging metadata from a `.env` file into the environment.

### `pkg_require_vars`

Usage: `pkg_require_vars <VAR...>`

Checks that required variables are set; returns non-zero when missing.

### `pkg_trim`

Usage: `pkg_trim <value>`

Trims whitespace from a string.

### `pkg_join_list`

Usage: `pkg_join_list <list> <separator>`

Joins a `|`-delimited list with the given separator.

### `pkg_quote_list`

Usage: `pkg_quote_list <list>`

Quotes each item from a `|`-delimited list (useful for Arch arrays).

### `pkg_render_lines`

Usage: `pkg_render_lines <prefix> <list>`

Renders a newline-separated list using the given prefix.

### `pkg_classify_name`

Usage: `pkg_classify_name <name>`

Converts a dashed/underscored name into CamelCase (Homebrew formula class).

### `pkg_guess_version`

Usage: `pkg_guess_version <repo_dir>`

Attempts to infer the version from `VERSION` or git tags; defaults to `0.1.0`.

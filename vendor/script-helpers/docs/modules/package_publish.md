# package_publish

Helpers for Debian package builds and Launchpad PPA publishing.

## Example

```
source ./helpers.sh
shlib_import logging package_publish

pkg_build_deb_artifacts "." "make man" ""
```

## Functions

### `pkg_require_cmds`

Usage: `pkg_require_cmds <cmd> [cmd...]`

Checks that required commands exist, logs missing commands, returns non-zero on failure.

### `pkg_run_prebuild`

Usage: `pkg_run_prebuild <command>`

Runs a prebuild command via `bash -lc` when provided.

### `pkg_set_series`

Usage: `pkg_set_series <series>`

Updates `debian/changelog` to the provided distro series using `dch`.

### `pkg_build_deb_artifacts`

Usage: `pkg_build_deb_artifacts <repo_dir> <prebuild_cmd> <build_cmd>`

Builds Debian package artifacts via `dpkg-buildpackage -us -uc` or a provided build command.

### `pkg_build_source_package`

Usage: `pkg_build_source_package <repo_dir> <prebuild_cmd> <build_cmd> <series> <key_id>`

Builds a signed Debian source package using `debuild -S -sa` and a GPG key ID.

Environment:
- `PPA_GPG_PASSPHRASE`: passphrase for non-interactive GPG signing.

### `pkg_find_changes_file`

Usage: `pkg_find_changes_file <repo_dir>`

Finds the first `.changes` file in the parent directory and prints its path.

### `pkg_upload_ppa`

Usage: `pkg_upload_ppa <ppa_target> <changes_file>`

Uploads the `.changes` file to a Launchpad PPA using `dput`.

# python

Helpers to resolve Python 3 executables and create local virtual environments.

Expected imports
----------------

- logging

Functions
---------

- python_version bin
  - Purpose: Print the Python major.minor version (e.g., `3.11`) for the given executable.
  - Returns: non-zero when the executable cannot be executed.

- python_has_min_version bin min_major min_minor
  - Purpose: Check if the given Python executable meets a minimum major/minor version.
  - Returns: zero when the version is satisfied; non-zero otherwise.

- python_can_run bin
  - Purpose: Check if the executable exists and is runnable (path or on PATH).

- python_pick_3 [min_major=3] [min_minor=8]
  - Purpose: Pick a `python3` (or `python`) executable that satisfies the minimum version.
  - Returns: Prints the command name on stdout; non-zero if none found.

- python_resolve_3 [requested] [min_major=3] [min_minor=8]
  - Purpose: Resolve a requested Python executable if valid; otherwise pick a suitable Python 3.
  - Returns: Prints the command name on stdout; non-zero if none found.

- python_ensure_venv python_bin venv_dir
  - Purpose: Ensure a venv exists at the given path and return its `python` path.
  - Returns: Prints the venv python path on stdout; non-zero on failure.
  - Behavior: Validates that the venv python is executable and functional before returning it.
  - Dependencies: `python -m venv` (may require `python3-venv` on Debian/Ubuntu).

Example
-------

```bash
source ./helpers.sh
shlib_import logging python

py="$(python_resolve_3 "" 3 8)" || exit 1
venv_py="$(python_ensure_venv "$py" "./.venv")" || exit 1
"$venv_py" -m pip install -e .
```

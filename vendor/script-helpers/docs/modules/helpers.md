# helpers

Loader and import utilities.

Functions
---------

- shlib_import names...
  - Purpose: Source module files by name from `lib/`.
  - Signature: `shlib_import name [name ...]`
  - Arguments:
    - name — module name without extension (e.g., `logging`, `docker`).
  - Behavior:
    - Ensures `logging` is available first unless it’s explicitly included.
    - Emits an error and returns non‑zero if a requested module is not found.
  - Example:
    ```bash
    source "$SCRIPT_HELPERS_DIR/helpers.sh"
    shlib_import logging env file
    ```

- shlib_import_all
  - Purpose: Convenience import for all modules found under `lib/*.sh`.
  - Signature: `shlib_import_all`
  - Returns: 0 on success.

Environment
-----------

- SCRIPT_HELPERS_DIR — path to this repository. The loader auto-detects when sourced; override when necessary.

Internals
---------

- _shlib_dir_resolve
  - Purpose: Resolve the root directory of the library based on `BASH_SOURCE` or `SCRIPT_HELPERS_DIR`.
  - Not intended for direct use.


# file

File/dir helpers and download utilities.

Functions
---------

- command_exists name
  - Purpose: Return success if a command is available in PATH.

- directory_exists path
- file_exists path
  - Purpose: Test for directory/file existence.

- create_directory path
  - Purpose: Create a directory if missing; prints a message. Returns 0 on success or if it already exists.

- download_file url [output]
  - Purpose: Download a file using `curl` or `wget`.
  - Behavior:
    - If `dialog` is installed and `DOWNLOAD_USE_DIALOG` is not `false`/`0`/`never`, automatically uses `dialog::dialog_download_file` for a progress gauge.
    - Falls back silently to `curl` or `wget` with minimal output.
  - Args:
    - url — source URL.
    - output — destination path; default derived from URL.
  - Env:
    - `DOWNLOAD_USE_DIALOG`: `auto` (default) | `true`/`1` | `false`/`0`/`never`.

- is_valid_iso file
  - Purpose: Heuristically check if a file is an ISO image (via `file`).

- is_valid_checksum file
  - Purpose: Heuristically check if a file looks like an ASCII checksum list.

- verify_checksum iso_file checksum_file [checksum_type=sha256sum]
  - Purpose: Verify checksum using the specified tool (e.g., `sha256sum`).
  - Returns: 0 on successful verification; prints success/error.

- download_iso distro_name
  - Purpose: Download ISO based on a `DISTROS` associative array defined by the caller.
  - Behavior: Prints success/error; validates ISO structure.

Dependencies
------------

- `curl` or `wget` for download, `dialog` for optional UI, `file` for validation.


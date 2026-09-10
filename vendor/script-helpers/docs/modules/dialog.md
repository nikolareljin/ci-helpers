# dialog

Dialog sizing, prompts, multi/single select, and a rich download progress gauge.

Functions
---------

- dialog_init
  - Purpose: Initialize `DIALOG_WIDTH`/`DIALOG_HEIGHT` based on the terminal size.

- check_if_dialog_installed
  - Purpose: Ensure `dialog` exists; prints an error and returns non-zero otherwise. Also calls `dialog_init`.

- get_value title message [default]
  - Purpose: Prompt a value using a dialog input box; prints the value to stdout.
  - Returns: 0 on success; non-zero (with error message) if canceled or empty.

> **Requires bash 4.0 or newer.** The two selectors below take a `DISTROS`
> associative array **from the caller**, which is the one contract in this
> library that cannot be expressed on bash 3.2. They call `require_bash4` and
> fail with an actionable message (`brew install bash` on macOS) rather than
> returning wrong values silently, which is what an associative array degrades
> to on bash 3.2. Everything else here runs on 3.2 unchanged.

- select_multiple_distros
  - Purpose: Checklist selection used by the iso-forge workflow.
  - Requirements: Associative array `DISTROS` mapping name -> URL must be defined by the caller.
  - Returns: space-separated selected names.

- select_distro
  - Purpose: Menu selection used by the iso-forge workflow.
  - Requirements: `DISTROS` associative array.
  - Returns: selected name.

- dialog_download_file url [output_path] [tool=auto]
  - Purpose: Download a URL with a live `dialog` gauge showing percentage, size, speed, and ETA.
  - Args:
    - url — source URL.
    - output_path — destination path (defaults from URL).
    - tool — `auto` (default), `curl`, or `wget`.
  - Behavior:
    - Shows progress while downloading; handles unknown `Content-Length` with rolling progress and no ETA.
    - On errors, shows a dialog box with exit code and error details unless disabled by env.
  - Returns: 0 on success; non-zero on failure/cancel.

Environment
-----------

- `DIALOG_WIDTH`, `DIALOG_HEIGHT` — set by `dialog_init`.
- `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` — set to `0`, `false`, or `never` to suppress dialog error popups in `dialog_download_file`.

Dependencies
------------

- `dialog`, `awk`, `stat` (GNU/BSD), and `curl` or `wget`.

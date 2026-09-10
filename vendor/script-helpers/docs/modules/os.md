# os

OS detection, shell capability probes and conditional sudo.

Functions
---------

- get_os
  - Purpose: Detect the current OS.
  - Returns: `linux`, `mac`, `windows`, or `unknown` based on `$OSTYPE`.
  - Notes: matches any `linux*` — bash reports `linux-musl` on Alpine and
    `linux-android` on Termux, and both are Linux. Reads `$OSTYPE` defensively,
    so a caller running under `set -u` gets `unknown` rather than an abort.

- getos
  - Purpose: Alias of `get_os` (compatibility).

- is_macos
  - Purpose: Test for macOS.
  - Returns: success when `get_os` is `mac`.

- is_linux
  - Purpose: Test for Linux (glibc, musl or Android).
  - Returns: success when `get_os` is `linux`.

- bash_major
  - Purpose: Print the major version of the running bash (`3`, `5`, ...).
  - Returns: `${BASH_VERSINFO[0]}`, or `0` when unset.

- bash_at_least major [minor]
  - Purpose: Test the running bash against a minimum version.
  - Args:
    - major — required major version.
    - minor — optional minimum minor version (default `0`).
  - Returns: success when the running bash is at least that version.
  - Example: `bash_at_least 4 || echo "no associative arrays here"`

- require_bash4 feature
  - Purpose: Fail loudly, with an actionable message, when the running bash
    predates 4.0. On macOS the message names `brew install bash`.
  - Args:
    - feature — what needs bash 4, named in the error.
  - Returns: `0` on bash 4+, `1` otherwise (logging through `log_error` when
    the logging module is loaded, else to stderr).
  - Notes: reserved for the few entry points that genuinely cannot work on bash
    3.2 — those taking an associative array **from the caller**, namely
    `select_distro`, `select_multiple_distros` and `download_iso`. Everything
    else in this library runs unchanged on bash 3.2, which is what macOS ships
    as `/bin/bash`; using this as a general guard would produce errors a caller
    cannot act on.

- is_wsl
  - Purpose: Detect whether script is running in WSL/WSL2.
  - Returns: success when `/proc/version` includes Microsoft or `WSL_DISTRO_NAME` is set.

- run_with_optional_sudo use_sudo_bool command [args...]
  - Purpose: Run a command with `sudo` when the first argument equals `true` and `sudo` exists.
  - Args:
    - use_sudo_bool — `true` to use sudo if available, anything else to run directly.
    - command [args...] — command to execute.
  - Returns: exit code of the underlying command.

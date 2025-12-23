# os

OS detection and conditional sudo.

Functions
---------

- get_os
  - Purpose: Detect the current OS.
  - Returns: `linux`, `mac`, `windows`, or `unknown` based on `$OSTYPE`.

- getos
  - Purpose: Alias of `get_os` (compatibility).

- run_with_optional_sudo use_sudo_bool command [args...]
  - Purpose: Run a command with `sudo` when the first argument equals `true` and `sudo` exists.
  - Args:
    - use_sudo_bool — `true` to use sudo if available, anything else to run directly.
    - command [args...] — command to execute.
  - Returns: exit code of the underlying command.


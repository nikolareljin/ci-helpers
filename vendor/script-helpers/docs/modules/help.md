# help

Render script help/usage information from header comments and provide common arg parsing.

Functions
---------

- display_help [script_file]
  - Purpose: Parse header tags from a script and print a concise help block using the shared renderer.
  - Signature: `display_help [path]`
  - Sets `SHLIB_HELP_SHOWN=true` for callers that want to skip UI cleanup.
  - Args: script_file — script to parse; defaults to `$0`.
  - Reads header keys: `# SCRIPT:`, `# DESCRIPTION:`, `# USAGE:`, `# PARAMETERS:`, `# EXAMPLE:`.

- print_help [script_file]
  - Purpose: Print a full help block from standard header tags using the shared renderer.
  - Signature: `print_help [path]`
  - Sets `SHLIB_HELP_SHOWN=true` for callers that want to skip UI cleanup.
  - Header keys: `SCRIPT`, `DESCRIPTION`, `AUTHOR`, `CREATED`, `VERSION`, `USAGE`, `PARAMETERS`.

- show_help [script_file]
  - Purpose: Help printer that scans header lines and prints Usage/Description/Parameters/Example/Exit Codes/Date/Version/Creator using the shared renderer.
  - Signature: `show_help [path]`
  - Sets `SHLIB_HELP_SHOWN=true` for callers that want to skip UI cleanup.
  - Behavior: uses `# USAGE:` when present; emits errors via `log_error` if the script file cannot be read.

- get_script_metadata script_file prefix
  - Purpose: Parse standardized header tags from a script into a set of shell variables.
  - Signature: `get_script_metadata <script_file> <prefix>`
  - Args:
    - script_file — script path to scan.
    - prefix — variable-name prefix to receive the fields.
  - Returns: `0` on success, `2` when `script_file` is missing or unreadable
    (checked up front, so a caller under `set -e` gets a controlled return and
    a message naming the path rather than a redirection error citing
    `lib/help.sh`), and `2` when `prefix` is missing or is not a valid
    shell variable name. The prefix becomes half a variable name, so an invalid
    one would otherwise turn every assignment into a `printf: not a valid
    identifier` error and leave the caller a half-filled set of variables; an
    empty one would silently write `_name`, `_usage` and so on.
  - Environment: none.
  - Dependencies: none beyond bash 3.1 (`printf -v`). `log_error` is used by callers, not by this function.
  - Notes: Sets `<prefix>_name`, `<prefix>_description`, `<prefix>_author`,
    `<prefix>_created`, `<prefix>_version`, `<prefix>_usage`,
    `<prefix>_parameters`, `<prefix>_example`, `<prefix>_exit_codes`,
    `<prefix>_date`, `<prefix>_creator`, plus `<prefix>_param_lines` holding the
    indented parameter lines. Fields absent from the header are set to the empty
    string, so re-using a prefix cannot leave stale values behind. Read them back
    directly or by indirect expansion:

    ```bash
    get_script_metadata ./tool.sh meta
    echo "$meta_version"
    ref="meta_usage"; echo "${!ref}"
    ```

    Supports multi-line values for `USAGE`, `PARAMETERS`, `EXAMPLE` and `EXIT_CODES`.
  - **Changed in 0.25.0**: the second argument was the name of an associative
    array, filled through a nameref. Associative arrays are bash 4.0 and
    namerefs bash 4.3, so every `--help` path in this library was dead on the
    bash 3.2 that macOS ships. Callers of `show_help`, `print_help` and
    `display_help` are unaffected; only direct callers of this function need to
    change, from `meta[usage]` to `meta_usage`.

- show_usage [script_file]
  - Purpose: Print generic usage with common options (`-h/--help`, `-v/--verbose`, `-d/--debug`).

- parse_common_args "$@"
  - Purpose: Parse common flags.
  - Flags:
    - `-h`, `--help` — prints `show_help` for the caller script when available; otherwise `show_usage`, then exits 0.
    - `-v`, `--verbose` — sets `VERBOSE=true`.
    - `-d`, `--debug` — sets `DEBUG=true`.
  - Stops parsing on the first non-flag.

Dependencies
------------

- Uses logging for output if imported; otherwise plain `echo` is used where applicable.

Environment
-----------

- `SHLIB_CALLER_SCRIPT` — optional; when set to a readable path, `parse_common_args` and helper usage output can render script-level help.

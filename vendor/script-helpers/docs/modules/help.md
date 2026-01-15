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

- get_script_metadata script_file meta_ref
  - Purpose: Parse standardized header tags from a script and populate an associative array with metadata fields.
  - Signature: `get_script_metadata <script_file> <meta_ref>`
  - Args:
    - script_file — script path to scan.
    - meta_ref — name of an associative array (nameref) to receive fields.
  - Returns: 0 on success; non-zero only if caller-provided references are invalid.
  - Environment: none.
  - Dependencies: bash nameref support; `log_error` is used by callers, not by this function.
  - Notes: Supports multi-line values for `USAGE`, `PARAMETERS`, `EXAMPLE`, and `EXIT_CODES`; also populates `param_lines` with indented parameter lines.

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

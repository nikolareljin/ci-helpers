# help

Render script help/usage information from header comments and provide common arg parsing.

Functions
---------

- display_help [script_file]
  - Purpose: Parse header tags from a script and print a colorized help block.
  - Signature: `display_help [path]`
  - Args: script_file — script to parse; defaults to `$0`.
  - Reads header keys: `# SCRIPT:`, `# DESCRIPTION:`, `# USAGE:`, `# PARAMETERS:`, `# EXAMPLE:`.

- print_help [script_file]
  - Purpose: Print a structured help block from standard header tags.
  - Signature: `print_help [path]`
  - Header keys: `SCRIPT`, `DESCRIPTION`, `AUTHOR`, `CREATED`, `VERSION`, `USAGE`, `PARAMETERS`.

- show_help [script_file]
  - Purpose: Robust help printer that scans header lines and prints Usage/Description/Parameters/Example/Exit Codes/Date/Version/Creator.
  - Signature: `show_help [path]`
  - Behavior: emits errors via `log_error` if the script file cannot be read.

- show_usage [script_file]
  - Purpose: Print generic usage with common options (`-h/--help`, `-v/--verbose`, `-d/--debug`).

- parse_common_args "$@"
  - Purpose: Parse common flags.
  - Flags:
    - `-h`, `--help` — prints `show_usage` and exits 0.
    - `-v`, `--verbose` — sets `VERBOSE=true`.
    - `-d`, `--debug` — sets `DEBUG=true`.
  - Stops parsing on the first non-flag.

Dependencies
------------

- Uses logging for output if imported; otherwise plain `echo` is used where applicable.


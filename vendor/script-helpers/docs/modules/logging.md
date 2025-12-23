# logging

Color printing and logging helpers for scripts.

Functions
---------

- print_color color|ansi text [text2] [color2]
  - Purpose: Print text in color; supports color names or raw ANSI codes.
  - Arguments:
    - color|ansi — name (`red`, `green`, `yellow`, `blue`, `cyan`, `magenta`, `white`, `grey`, `bold`, `underline`) or ANSI code constant.
    - text — first line to print.
    - text2 — optional second line to print (different color supported).
    - color2 — optional color for the second line; defaults to the first color.
  - Returns: 0.

- print_info message
- print_error message
- print_success message
- print_warning message
- print_line
  - Purpose: Convenience wrappers around `print_color` with common prefixes and styles.
  - Output: writes to stdout except `log_*` variants write to stderr (see below).

- log_info message
- log_warn message
- log_error message
- log_debug message
  - Purpose: Logging to stderr with level prefixes.
  - Environment: `DEBUG=true` enables `log_debug` output.
  - Returns: Always 0 (safe with `set -e`) even when no debug output is emitted.

- print color message...
  - Purpose: Compatibility wrapper used by some legacy scripts; prints and then echoes `....`.

- print_red|print_green|print_yellow|print_blue message
  - Purpose: Color-specific shortcuts.

Notes
-----

- Color constants like `RED`, `GREEN` etc. are defined if you want to use raw ANSI codes directly.

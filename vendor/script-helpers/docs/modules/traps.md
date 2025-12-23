# traps

Basic EXIT/INT/TERM traps with error reporting.

Functions
---------

- cleanup
  - Purpose: Trap handler that prints a non-zero exit code via `log_error` when a script exits with failure.

- setup_traps
  - Purpose: Install traps: `EXIT` → `cleanup`, `INT` → prints interrupt and exits 130, `TERM` → prints terminated and exits 143.

Notes
-----

- Import `logging` to format trap errors as styled logs.


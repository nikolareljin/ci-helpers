# clipboard

Copy text to the system clipboard.

Functions
---------

- copy_to_clipboard text
  - Purpose: Copy a string to the clipboard.
  - Behavior: Uses `xclip` on Linux, `pbcopy` on macOS. Prints a confirmation or an error when no supported tool is found.

Dependencies
------------

- Linux: `xclip` (installs via package manager).
- macOS: `pbcopy` (part of macOS; ensure Xcode CLI tools when missing).


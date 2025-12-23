# deps

Install a set of development/runtime dependencies. These helpers may use network and elevated privileges.

Functions
---------

- install_dependencies [pkg...]
  - Purpose: Install packages using the available package manager.
  - Args: list of packages; if omitted, installs a common set: `dialog curl jq wget util-linux`.
  - Behavior: Detects and uses `apt-get`, `dnf`, `pacman`, or `brew`. Uses `sudo` when available.

- install_dependencies_ai_runner
  - Purpose: Install a profile of tools typically used by AI Runner/HelperGPT workflows.
  - Behavior:
    - Ensures: `dialog`, `curl`, `jq`, `python3`, `pip3`, `nodejs` (>=20), `npm`/`npx`, `git`, and `ollama`.
    - Installs clipboard utilities (`xclip` on Linux) as needed.
    - Uses platform-specific package managers and installers; may require `sudo`.
  - Notes: Prints messages for unsupported platforms or manual steps when necessary.

Dependencies
------------

- Package managers: `apt-get`, `dnf`, `pacman`, `brew`. Network access is required.


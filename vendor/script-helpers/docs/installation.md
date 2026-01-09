# Installation

Options
-------

- Vendor as a subfolder (recommended for local repos):
  - Copy or symlink this folder into your project (e.g., `scripts/script-helpers`).
  - Point `SCRIPT_HELPERS_DIR` to that folder in your scripts and `source helpers.sh`.

- Git submodule (once hosted remotely):
  - `git submodule add <repo-url> scripts/script-helpers`
  - `git submodule update --init --recursive`
  - Source as shown in the quick start.
  - Create a `scripts/update.sh` in your repo that runs `git submodule update --init --recursive` (see `docs/usage.md` for a sample).
  - Add a root-level `./update` symlink to that script: `ln -s ./scripts/update.sh ./update`

Loader location
---------------

- The loader resolves its own location automatically when you `source helpers.sh`.
- You can override the path via `SCRIPT_HELPERS_DIR` if needed (e.g., when running from different working directories).

Dependencies
------------

Core
- A POSIX-ish shell (tested with bash), common coreutils.

Per-module
- logging: none.
- help: none.
- os: `sudo` for privileged commands (optional).
- env: none.
- file: `curl` or `wget`; optionally `dialog` for progress gauge; `file` for ISO/checksum checks.
- dialog: `dialog`, `awk`, `stat`, `curl` or `wget` for downloads.
- docker: Docker CLI; either `docker compose` (v2) or `docker-compose` (v1).
- json: `jq` for JSON formatting/extraction.
- ports: `lsof`/`ss`/`netstat`/`fuser` (uses what is available); may use `sudo` if allowed.
- browser: `xdg-open`/`open`/`gio` depending on OS; `nc`/`telnet` for port checks.
- certs: `openssl`; OS tools like `update-ca-certificates`, `security`, `trust` depending on platform; may use `sudo`.
- hosts: `sudo` to append to `/etc/hosts`.
- clipboard: `xclip` on Linux or `pbcopy` on macOS.
- traps: none.
- ollama: `curl`, `git`, `python3`, `jq`, `dialog`, and the `ollama` CLI (installer included for Linux/macOS).

Network and sudo notes
----------------------

- Some helpers can use network (e.g., downloads, git clone) or require elevated privileges (e.g., trust store, /etc/hosts). Those functions call out the behavior in their docs and use `run_with_optional_sudo` when appropriate.

# Script Helpers — Documentation

Reusable Bash helpers extracted from projects in this workspace. Source the loader, import only the modules you need, and call the functions in your own scripts.

- Installation: see ./docs/installation.md
- Usage: see ./docs/usage.md
- Packaging: see ./docs/packaging.md
- Full API: see ./docs/api.md

Quick start
-----------

```bash
#!/usr/bin/env bash
set -euo pipefail

# Point to the script-helpers folder in your repo
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"

# Load loader and import modules you need
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard ollama os

print_success "script-helpers is ready"
```

Modules overview
----------------

- helpers — loader and import utilities.
- logging — color and log utilities for both stdout and stderr.
- help — print help/usage from script header comments and common arg parsing.
- os — OS detection and conditional sudo runner.
- env — project root detection, .env loading, require envs.
- file — file/dir checks, download with optional dialog gauge, ISO/checksum helpers.
- dialog — `dialog` sizing, input, and a rich download progress gauge.
- docker — docker compose detection/wrapper, service wait, status inspection.
- deps — install utilities and AI Runner tooling profile.
- json — escape strings, extract fields, markdown-friendly formatting.
- ports — list port listeners, detect conflicts from env variables.
- version — semantic version helpers for bumping and comparing.
- browser — open URLs and wait+open a frontend when ready.
- certs — self‑signed certs and trust store installation.
- hosts — /etc/hosts helpers.
- clipboard — copy text to clipboard (Linux/macOS).
- traps — simple EXIT/INT/TERM traps with error reporting.
- ollama — install CLI, prepare models index, select/pull/run models.
- package_publish — Debian package builds and PPA upload helpers.
- packaging — packaging metadata helpers and template formatting.

If you add a new module or function, update ./docs/api.md and the relevant ./docs/modules/*.md file. See AGENTS.md for the process and checklist.

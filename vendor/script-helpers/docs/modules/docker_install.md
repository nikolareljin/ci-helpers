# docker_install

Docker installation helpers — Docker Engine on Linux, Docker Desktop on macOS and Windows, with explicit WSL handling.

Companion to [`docker`](./docker.md): that module assumes Docker exists and helps you drive it. This one gets it onto the machine, so a project bootstrap script can go from a bare host to a working `docker compose` without sending the operator off to read platform-specific install docs.

Depends on: `logging`, `os`.

```bash
source ./helpers.sh
shlib_import logging os docker_install

ensure_docker --yes    # no-op if Docker already works; installs it otherwise
```

> These functions modify the system. They add package repositories, install system packages, and on Linux change group membership — all needing sudo or Administrator. Nothing runs without confirmation unless `--yes` is passed.

What gets installed
-------------------

| Platform | Package | Method |
| -------- | ------- | ------ |
| Linux | Docker Engine + compose v2 plugin | Docker's official repositories via `apt` / `dnf` / `yum`; distribution packages on openSUSE and Arch |
| macOS | Docker Desktop | Homebrew cask when present, otherwise the official `.dmg` for the detected CPU |
| Windows | Docker Desktop | `winget`, then Chocolatey, then the official silent installer — from Git Bash / MSYS2 |
| WSL | Either — see below | Detected explicitly; both options explained before anything is installed |

Functions
---------

### Detection

- docker_cli_installed
  - Purpose: the `docker` binary is on `PATH`.
  - Returns: 0 when present.

- docker_daemon_running
  - Purpose: the CLI can reach a live daemon (`docker info`).
  - Returns: 0 when reachable.

- docker_compose_v2_available
  - Purpose: `docker compose` (v2, the plugin) works.
  - Returns: 0 when available.

- docker_ready
  - Purpose: CLI, daemon and compose v2 all work. This is the condition most projects actually care about.
  - Returns: 0 when all three hold.

- docker_install_status
  - Purpose: single-word state for scripting.
  - Returns: prints `ready`, `no-cli`, `no-daemon` or `no-compose`.

- docker_report_state
  - Purpose: log what is present, with versions.
  - Returns: 0 only when Docker is fully ready.

### Installation

- install_docker [--yes] [--dry-run] [--no-start] [--no-group] [--timeout N]
  - Purpose: install Docker for the detected platform.
  - Behaviour: idempotent — returns 0 immediately when Docker is already usable. When the CLI exists but the daemon does not respond it **starts what is already installed** before installing anything; a closed Docker Desktop is the common case and reinstalling is the wrong fix. Prints its plan and asks for confirmation before modifying anything.
  - Options:
    - `-y`, `--yes` — non-interactive; required when there is no TTY.
    - `-n`, `--dry-run` — print every command that would run, change nothing.
    - `--no-start` — install but do not start the daemon or launch Desktop.
    - `--no-group` — Linux only: skip adding the user to the `docker` group.
    - `--timeout N` — positive integer seconds to wait for the daemon. Default 120.
  - Returns: `0` ready · `1` failed or declined · `2` bad usage or unsupported platform · `3` installed but the daemon did not come up in time.

- ensure_docker [install_docker options...]
  - Purpose: idempotent guard for bootstrap scripts. Succeeds silently when Docker is already usable, otherwise delegates to `install_docker`.
  - Returns: `install_docker`'s exit code.

### Pieces you can call directly

- docker_start_daemon
  - Purpose: start the Linux daemon via `systemctl enable --now docker`, falling back to `service docker start`.
  - Returns: non-zero when neither is available.

- docker_add_user_to_group [user]
  - Purpose: add a user to the `docker` group so Docker works without `sudo`. Defaults to the current user.
  - Returns: `0` when already a member or running as root; **`10`** when the group was added but the current shell cannot use it yet — group membership does not apply to an already-running session.
  - Note: membership of `docker` is effectively root-equivalent. The function warns about this.

- wait_for_docker_daemon [timeout_seconds]
  - Purpose: poll `docker info` until it answers.
  - Returns: `0` when ready, `1` on timeout, or `2` when the timeout is not a positive integer. Default timeout 120s.

Exit code 3 and what to do about it
-----------------------------------

`install_docker` returns `3` when the install succeeded but the daemon was not reachable before the timeout. It is not a failure, and the cause differs by platform:

- **Linux** — almost always the `docker` group change not applying to the current shell. `newgrp docker`, or log out and back in.
- **macOS / Windows** — Docker Desktop is still starting, or waiting on a password, a licence prompt, or a reboot to finish enabling WSL2 or Hyper-V.

Distribution handling
---------------------

Docker publishes apt repositories for `debian` and `ubuntu` only, so derivatives are mapped onto their upstream: Mint, Pop!\_OS, KDE neon, Zorin and elementary → `ubuntu`; Raspbian, Kali and Parrot → `debian`. Anything else falls back on `ID_LIKE`.

The repository line uses `UBUNTU_CODENAME` in preference to `VERSION_CODENAME`, because on derivatives the latter is the derivative's own release name, which Docker's repository does not know about — using it produces a 404 at `apt-get update`.

For dnf/yum, RHEL, CentOS, Rocky, AlmaLinux and Oracle Linux map onto `centos`; Fedora uses its own repository.

openSUSE has no official Docker repository, so the distribution package is used and the function says so.

WSL
---

Two options, and they are not equivalent. `install_docker` detects WSL and explains both before doing anything:

1. **Docker Desktop on Windows with WSL integration** — recommended. Install from Windows, then enable integration for the distro in Docker Desktop → Settings → Resources → WSL Integration. One Docker shared across Windows and every distro.
2. **Docker Engine inside the distro** — what continuing installs. WSL1 cannot run it at all; on WSL2 without systemd the daemon must be started each session with `sudo service docker start`.

CLI wrapper
-----------

`bin/install-docker` exposes the same behaviour as a standalone command, plus `--check`, which reports whether Docker is usable and exits without installing anything.

```bash
bin/install-docker --check    # 0 = usable, 1 = not
bin/install-docker -n         # dry run
bin/install-docker -y         # unattended
```

PowerShell
----------

`ps/lib/docker_install.ps1` is the native Windows counterpart — no WSL or Git Bash needed. Function names mirror the Bash module, so everything above applies.

```powershell
. .\ps\helpers.ps1
Import-ScriptHelpers logging os docker_install

if ((ensure_docker -Yes) -ne 0) { throw "Docker required" }
```

Switch parameters replace the Bash flags: `-Yes`, `-DryRun`, `-NoStart`, `-TimeoutSec`. Exit codes are identical.

`ps/scripts/install_docker.ps1` is the CLI wrapper, matching `bin/install-docker`:

```powershell
.\ps\scripts\install_docker.ps1 -Check     # 0 = usable, 1 = not
.\ps\scripts\install_docker.ps1 -DryRun
.\ps\scripts\install_docker.ps1 -Yes
```

Platform coverage differs from the Bash module, deliberately:

| Platform | PowerShell module | Notes |
| --- | --- | --- |
| **Windows** | Full support | The primary target. `winget` → Chocolatey → official installer. Warns when not elevated rather than failing opaquely on a UAC error |
| **macOS** | Homebrew cask only | PowerShell 7 runs here, but the `.dmg` path needs `hdiutil` and a privileged helper — use the Bash module for a machine without Homebrew |
| **Linux** | Defers to Bash | Returns an error naming the Bash entry point. Package-manager detection and the `docker` group belong in the Bash module; duplicating them in PowerShell would be two implementations to keep correct |

Two Windows-specific details worth knowing:

- The installer download sets TLS 1.2 explicitly. Windows PowerShell 5.1 does not negotiate it by default and the download fails outright without this.
- `$ProgressPreference` is silenced around `Invoke-WebRequest`; the progress bar makes a large download roughly an order of magnitude slower.

Example: project bootstrap
--------------------------

```bash
#!/usr/bin/env bash
set -euo pipefail
source scripts/script-helpers/helpers.sh
shlib_import logging os docker_install

if ! ensure_docker; then
  case "$?" in
    3) log_warn "Docker installed but not up yet — see the note above, then re-run." ;;
    *) log_error "Cannot continue without Docker."; exit 1 ;;
  esac
  exit 1
fi

docker compose up -d
```

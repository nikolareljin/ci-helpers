# Docker installation helpers — PowerShell companion to lib/docker_install.sh.
#
# Companion to docker.ps1: that module assumes Docker exists and helps you drive
# it. This one gets it onto the machine, so a bootstrap script can go from a bare
# host to a working `docker compose` without sending the operator off to read
# install docs.
#
# Windows is the primary target — Docker Desktop is the mechanism there, not a
# convenience, since Windows does not run the Linux container engine natively.
# The Linux and macOS branches work under PowerShell 7 for parity; on those
# platforms the Bash module is usually the better entry point.
#
# Function names mirror the Bash module so the docs are shared.
#
# Requires: logging, os

# --- detection -------------------------------------------------------------

function docker_cli_installed {
    return [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

function docker_daemon_running {
    if (-not (docker_cli_installed)) { return $false }
    docker info 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function docker_compose_v2_available {
    if (-not (docker_cli_installed)) { return $false }
    docker compose version 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Docker is usable end to end. This is the condition most projects care about.
function docker_ready {
    return ((docker_cli_installed) -and (docker_daemon_running) -and (docker_compose_v2_available))
}

# Prints one of: ready | no-cli | no-daemon | no-compose
function docker_install_status {
    if (-not (docker_cli_installed))        { return 'no-cli' }
    if (-not (docker_daemon_running))       { return 'no-daemon' }
    if (-not (docker_compose_v2_available)) { return 'no-compose' }
    return 'ready'
}

# Logs what is present, with versions. Returns $true only when fully ready.
function docker_report_state {
    if (-not (docker_cli_installed)) {
        log_warn "Docker CLI: not found"
        return $false
    }
    $v = (docker --version 2>$null | Out-String).Trim()
    if (-not $v) { $v = 'present, version unknown' }
    log_info "Docker CLI: $v"

    if (-not (docker_daemon_running)) {
        log_warn "Docker daemon: not reachable"
        return $false
    }
    log_info "Docker daemon: reachable"

    if (docker_compose_v2_available) {
        $cv = (docker compose version --short 2>$null | Out-String).Trim()
        if (-not $cv) { $cv = 'present' }
        log_info "Compose plugin: $cv"
    } else {
        log_warn "Compose plugin: not found ('docker compose' v2 unavailable)"
        return $false
    }
    return $true
}

# --- internals -------------------------------------------------------------

$script:_ShlibDockerDryRun    = $false
$script:_ShlibDockerAssumeYes = $false

function _Shlib_Docker_Run {
    param([Parameter(Mandatory)][string]$Exe,
          [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($script:_ShlibDockerDryRun) {
        Write-Host "  [dry-run] $Exe $($Arguments -join ' ')"
        return 0
    }
    & $Exe @Arguments
    return $LASTEXITCODE
}

function _Shlib_Docker_Confirm {
    param([string]$Prompt)
    if ($script:_ShlibDockerAssumeYes) { return $true }
    if ($script:_ShlibDockerDryRun)    { return $true }
    # No interactive host (CI, a service, a redirected console): refuse rather
    # than block forever waiting on input nobody can supply.
    if ([Console]::IsInputRedirected) {
        log_error "No interactive console and -Yes was not passed."
        return $false
    }
    $reply = Read-Host "$Prompt [y/N]"
    return ($reply -match '^[Yy]$')
}

# Usage: wait_for_docker_daemon [-TimeoutSec 120]
# Polls `docker info` until it answers. Returns $true on success.
function wait_for_docker_daemon {
    param([int]$TimeoutSec = 120)
    if ($script:_ShlibDockerDryRun) { return $true }
    $waited = 0
    log_info "Waiting for the Docker daemon (up to ${TimeoutSec}s)…"
    while ($waited -lt $TimeoutSec) {
        if (docker_daemon_running) {
            log_info "Docker daemon is up after ${waited}s."
            return $true
        }
        Start-Sleep -Seconds 3
        $waited += 3
        if ($waited % 15 -eq 0) { log_info "  …still waiting (${waited}s)" }
    }
    return $false
}

# --- platform install paths ------------------------------------------------

function _Shlib_Docker_DesktopPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles      'Docker\Docker\Docker Desktop.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe')
    ) | Where-Object { $_ }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function _Shlib_Docker_InstallWindowsFallback {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        log_info "Installing via Chocolatey."
        $rc = _Shlib_Docker_Run 'choco' 'install' 'docker-desktop' '-y'
        if ($rc -eq 0) { return $true }
        log_warn "Chocolatey install failed — falling back to the official installer."
    }

    log_info "Downloading the official Docker Desktop installer."
    $url = 'https://desktop.docker.com/win/main/amd64/Docker Desktop Installer.exe'
    $exe = Join-Path ([System.IO.Path]::GetTempPath()) 'DockerDesktopInstaller.exe'

    if ($script:_ShlibDockerDryRun) {
        Write-Host "  [dry-run] Invoke-WebRequest '$url' -OutFile '$exe'"
        Write-Host "  [dry-run] & '$exe' install --quiet --accept-license"
        return $true
    }

    try {
        # Explicit TLS 1.2 for Windows PowerShell 5.1, which does not negotiate
        # it by default and otherwise fails the download outright.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'   # the progress bar makes this ~10x slower
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    } catch {
        log_error "Download failed: $($_.Exception.Message)"
        log_error "Install manually: https://docs.docker.com/desktop/install/windows-install/"
        return $false
    }

    log_info "Running the installer silently (several minutes)."
    $p = Start-Process -FilePath $exe -ArgumentList 'install', '--quiet', '--accept-license' -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        log_error "Installer exited $($p.ExitCode). Run it interactively: $exe"
        return $false
    }
    return $true
}

function _Shlib_Docker_InstallWindows {
    param([switch]$NoStart)

    if (-not (is_admin)) {
        log_warn "Not running as Administrator. Installing Docker Desktop needs elevation."
        log_warn "If this fails, re-open PowerShell with 'Run as Administrator' and retry."
    }

    $ok = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        log_info "Installing via winget."
        $rc = _Shlib_Docker_Run 'winget' 'install' '--id' 'Docker.DockerDesktop' '-e' '--silent' `
                                '--accept-package-agreements' '--accept-source-agreements'
        if ($rc -eq 0) {
            $ok = $true
        } else {
            log_warn "winget install failed (exit $rc) — falling back."
            $ok = _Shlib_Docker_InstallWindowsFallback
        }
    } else {
        $ok = _Shlib_Docker_InstallWindowsFallback
    }
    if (-not $ok) { return $false }

    if (-not $NoStart) {
        $desktop = _Shlib_Docker_DesktopPath
        if ($desktop) {
            log_info "Launching Docker Desktop."
            if ($script:_ShlibDockerDryRun) {
                Write-Host "  [dry-run] Start-Process '$desktop'"
            } else {
                Start-Process -FilePath $desktop | Out-Null
            }
        } else {
            log_warn "Docker Desktop not found at the default path — launch it from the Start menu."
        }
        log_info "A reboot may be needed to finish enabling WSL2 or Hyper-V."
    }
    return $true
}

function _Shlib_Docker_InstallMac {
    param([switch]$NoStart)
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        log_info "Installing Docker Desktop via Homebrew."
        # The cask was renamed from `docker` to `docker-desktop`; try the current
        # name first so this also works on older Homebrew installations.
        $rc = _Shlib_Docker_Run 'brew' 'install' '--cask' 'docker-desktop'
        if ($rc -ne 0) {
            log_warn "Cask 'docker-desktop' unavailable — trying legacy cask 'docker'."
            $rc = _Shlib_Docker_Run 'brew' 'install' '--cask' 'docker'
        }
        if ($rc -ne 0) { return $false }
    } else {
        log_error "Homebrew not found. Under PowerShell the macOS path requires brew."
        log_error "Use the Bash module (lib/docker_install.sh), which also handles the .dmg."
        return $false
    }
    if (-not $NoStart) { _Shlib_Docker_Run 'open' '-a' 'Docker' | Out-Null }
    return $true
}

function _Shlib_Docker_InstallLinux {
    param([switch]$NoStart)
    log_error "Installing Docker Engine on Linux from PowerShell is not supported."
    log_error "Use the Bash module — it handles apt/dnf/yum/zypper/pacman and the docker group:"
    log_error "  source helpers.sh && shlib_import logging os docker_install && install_docker"
    return $false
}

# Usage: docker_start_daemon
# Starts Docker Desktop on Windows/macOS, or the systemd service on Linux.
function docker_start_daemon {
    switch (get_os) {
        'windows' {
            $desktop = _Shlib_Docker_DesktopPath
            if (-not $desktop) { log_warn "Docker Desktop not installed."; return $false }
            if ($script:_ShlibDockerDryRun) {
                Write-Host "  [dry-run] Start-Process '$desktop'"
            } else {
                Start-Process -FilePath $desktop | Out-Null
            }
            return $true
        }
        'mac' { _Shlib_Docker_Run 'open' '-a' 'Docker' | Out-Null; return $true }
        'linux' {
            if (Get-Command systemctl -ErrorAction SilentlyContinue) {
                _Shlib_Docker_Run 'sudo' 'systemctl' 'enable' '--now' 'docker' | Out-Null
                return $true
            }
            log_warn "systemctl not found — start the Docker daemon manually."
            return $false
        }
        default { return $false }
    }
}

# --- public entry points ---------------------------------------------------

<#
.SYNOPSIS
Install Docker for the current platform. Idempotent.

.DESCRIPTION
Installs Docker Desktop on Windows (winget, then Chocolatey, then the official
installer) and macOS (Homebrew cask). On Linux it defers to the Bash module,
which handles the package managers and the docker group properly.

Returns 0 when Docker is ready, 1 on failure or when declined, 2 for an
unsupported platform, and 3 when the install succeeded but the daemon did not
become reachable in time.

.PARAMETER Yes
Non-interactive; assume yes. Required when there is no interactive console.

.PARAMETER DryRun
Print what would run; change nothing.

.PARAMETER NoStart
Install but do not launch Docker Desktop / start the daemon.

.PARAMETER TimeoutSec
Seconds to wait for the daemon. Default 120 — Docker Desktop is slow to start.

.EXAMPLE
install_docker -Yes

.EXAMPLE
install_docker -DryRun
#>
function install_docker {
    param(
        [Alias('y')][switch]$Yes,
        [Alias('n')][switch]$DryRun,
        [switch]$NoStart,
        [switch]$NoGroup,          # accepted for parity with Bash; unused on Windows
        [int]$TimeoutSec = 120
    )

    $script:_ShlibDockerDryRun    = [bool]$DryRun
    $script:_ShlibDockerAssumeYes = [bool]$Yes

    $os = get_os
    $wsl = if (is_wsl) { ' (WSL)' } else { '' }
    log_info "Docker installer — platform: ${os}${wsl}"

    if (docker_ready) {
        docker_report_state | Out-Null
        log_info "Docker is already installed and working."
        return 0
    }

    # CLI present but no daemon: start what is already installed before
    # installing anything. A closed Docker Desktop is the common case, and
    # reinstalling is the wrong fix for it.
    if ((docker_cli_installed) -and -not (docker_daemon_running) -and -not $NoStart) {
        log_warn "Docker CLI found but the daemon is unreachable — trying to start it."
        docker_start_daemon | Out-Null
        if ((wait_for_docker_daemon -TimeoutSec $TimeoutSec) -and (docker_ready)) {
            docker_report_state | Out-Null
            log_info "Docker is working now — no installation needed."
            return 0
        }
        log_warn "Still unreachable — proceeding with installation."
    }

    switch ($os) {
        'windows' { log_info "Plan: Docker Desktop (winget, then Chocolatey, then the official installer), then launch it." }
        'mac'     { log_info "Plan: Docker Desktop via Homebrew cask, then launch it." }
        'linux'   { log_info "Plan: defer to the Bash module." }
        default {
            log_error "Unsupported platform: $os"
            log_error "Install Docker manually: https://docs.docker.com/get-docker/"
            return 2
        }
    }

    log_warn "This modifies the system: it installs software and may require a reboot."
    if (-not (_Shlib_Docker_Confirm "Continue?")) {
        log_info "Aborted — nothing changed."
        return 1
    }

    $ok = switch ($os) {
        'windows' { _Shlib_Docker_InstallWindows -NoStart:$NoStart }
        'mac'     { _Shlib_Docker_InstallMac     -NoStart:$NoStart }
        'linux'   { _Shlib_Docker_InstallLinux   -NoStart:$NoStart }
        default   { $false }
    }
    if (-not $ok) {
        log_error "Docker installation failed."
        return 1
    }

    if ($script:_ShlibDockerDryRun) {
        log_info "Dry run complete — nothing was changed."
        return 0
    }
    if ($NoStart) {
        log_info "Installed. Daemon not started (-NoStart)."
        return 0
    }

    if (wait_for_docker_daemon -TimeoutSec $TimeoutSec) {
        docker_report_state | Out-Null
        log_info "Docker is ready."
        return 0
    }

    log_warn "Installed, but the daemon did not become reachable in ${TimeoutSec}s."
    log_warn "Docker Desktop is probably still starting, or waiting on a prompt or a reboot."
    return 3
}

<#
.SYNOPSIS
Idempotent guard for bootstrap scripts.

.DESCRIPTION
Succeeds silently when Docker is already usable, otherwise delegates to
install_docker. Returns install_docker's exit code.

.EXAMPLE
if ((ensure_docker -Yes) -ne 0) { throw "Docker required" }
#>
function ensure_docker {
    param(
        [Alias('y')][switch]$Yes,
        [Alias('n')][switch]$DryRun,
        [switch]$NoStart,
        [switch]$NoGroup,
        [int]$TimeoutSec = 120
    )
    if (docker_ready) {
        log_debug "Docker already usable — nothing to do."
        return 0
    }
    return (install_docker -Yes:$Yes -DryRun:$DryRun -NoStart:$NoStart -NoGroup:$NoGroup -TimeoutSec $TimeoutSec)
}

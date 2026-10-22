# SCRIPT: install_docker.ps1
# DESCRIPTION: Install or report Docker Desktop through the native PowerShell wrapper.
# USAGE: pwsh -File ps\scripts\install_docker.ps1 [-Check] [-Yes] [-DryRun] [-NoStart] [-TimeoutSec <seconds>]
# PARAMETERS:
#   -Check                 Report Docker state without installing.
#   -Yes                   Skip confirmation prompts.
#   -DryRun                Print the planned actions without changing the machine.
#   -NoStart               Install Docker Desktop without launching it.
#   -TimeoutSec <seconds>  Daemon wait time (default: 120).
#   -Help                  Show this help message.
# EXIT_CODES:
#   0  Docker is usable or installation completed.
#   1  Docker is unavailable, installation failed, the user declined, or a
#      parameter is unknown.
#   2  Unsupported platform.
#   3  Installation completed but the daemon did not become ready.
# EXAMPLE: pwsh -File ps\scripts\install_docker.ps1 -Check
# ----------------------------------------------------
<#
.SYNOPSIS
Install Docker for the current platform - PowerShell counterpart to bin/install-docker.

.DESCRIPTION
Thin wrapper around the docker_install module. Idempotent: reports and exits
when Docker is already usable. On Windows this installs Docker Desktop via
winget, then Chocolatey, then the official installer.

Exit codes: 0 usable; 1 failed, declined or an unknown parameter; 2 unsupported
platform; 3 installed but the daemon did not come up in time.

.PARAMETER Check
Report whether Docker is usable, then exit. Installs nothing.

.PARAMETER Yes
Non-interactive; assume yes. Required with no interactive console.

.PARAMETER DryRun
Print what would run; change nothing.

.PARAMETER NoStart
Install but do not launch Docker Desktop.

.PARAMETER TimeoutSec
Seconds to wait for the daemon. Default 120.

.EXAMPLE
.\install_docker.ps1 -Check

.EXAMPLE
.\install_docker.ps1 -Yes
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [Alias('y')][switch]$Yes,
    [Alias('n')][switch]$DryRun,
    [switch]$NoStart,
    [int]$TimeoutSec = 120,
    [switch]$Help
)
# -Help: print the header above and stop, before anything runs.
if ($Help) { foreach ($l in Get-Content -LiteralPath $PSCommandPath) { if ($l -match '^#\s*-{4,}') { break }; $l -replace '^# ?', '' }; exit 0 }

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'helpers.ps1')
Import-ScriptHelpers logging os docker_install

if ($Check) {
    if (docker_report_state) {
        log_info "Docker is installed and usable."
        exit 0
    }
    log_warn "Docker is not usable. Run this script without -Check to install it."
    exit 1
}

exit (install_docker -Yes:$Yes -DryRun:$DryRun -NoStart:$NoStart -TimeoutSec $TimeoutSec)

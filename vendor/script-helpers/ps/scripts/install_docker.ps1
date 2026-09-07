<#
.SYNOPSIS
Install Docker for the current platform — PowerShell counterpart to bin/install-docker.

.DESCRIPTION
Thin wrapper around the docker_install module. Idempotent: reports and exits
when Docker is already usable. On Windows this installs Docker Desktop via
winget, then Chocolatey, then the official installer.

Exit codes: 0 usable · 1 failed or declined · 2 bad usage · 3 installed but the
daemon did not come up in time.

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
    [int]$TimeoutSec = 120
)

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

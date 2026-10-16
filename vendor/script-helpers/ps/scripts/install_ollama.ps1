<#
.SYNOPSIS
Install or upgrade Ollama on Windows from a checked source: PowerShell counterpart to scripts/install_ollama.sh.

.DESCRIPTION
Thin wrapper around the ollama_install module: winget (an older Ollama is upgraded),
else the pinned release zip, checked against its SHA-256 and unpacked per user.

Exit codes: 0 installed, upgraded or nothing to do (with -Check: nothing to do);
1 the download failed or does not match the pin (with -Check: it would install or
upgrade); 2 bad usage; 3 no checkable source for this platform.

.PARAMETER Prefix
Install the release zip into this directory; winget is not used.

.PARAMETER Force
Install even when the pinned version or a newer one is there.

.PARAMETER Check
Say what is installed and what is pinned, and what would happen. Changes nothing.

.EXAMPLE
.\ps\scripts\install_ollama.ps1 -Check

.EXAMPLE
.\ps\scripts\install_ollama.ps1 -Prefix $env:TEMP\ollama-test
#>
[CmdletBinding()]
param(
    [string]$Prefix = '',
    [switch]$Force,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot '..') 'helpers.ps1')
Import-ScriptHelpers ci_defaults ollama_install

if ($Check) {
    $pinned = $env:CI_DEFAULT_OLLAMA_VERSION
    $asset = ollama_install_asset
    if (-not $asset) { $asset = 'none (no checkable zip for this platform)' }
    $have = ollama_installed_version
    if ($have) {
        $where = (Get-Command ollama).Source
        if (_ollama_install_at_least $have $pinned) {
            log_info "Ollama $have at $where; pinned $pinned. Nothing to do."
            exit 0
        }
        log_info "Ollama $have at $where; pinned $pinned. It would be upgraded (zip: $asset)."
        exit 1
    }
    log_info "No Ollama on PATH; pinned $pinned. It would be installed (zip: $asset)."
    exit 1
}

$rc = if ($Prefix) { ollama_install -Prefix $Prefix -Force:$Force } else { ollama_install -Force:$Force }
exit $rc

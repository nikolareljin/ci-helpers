<#
.SYNOPSIS
Real-machine check of ollama_install on Windows: PowerShell counterpart to tests/machine/ollama_install_check.sh.

.DESCRIPTION
Downloads the pinned Ollama release zip, installs it into throwaway directories and
checks install, verify, refuse, upgrade and staging. winget and the Ollama already
installed are not touched: every case uses -Prefix, which skips winget.

Not part of the unit tests: it downloads the real release (over 1 GB) and runs the
real ollama.exe.

Exit codes: 0 every case passed; 1 a case failed; 2 this machine cannot run the check.

.PARAMETER Keep
Leave the throwaway directory for inspection (its path is printed).

.EXAMPLE
pwsh -NoProfile -File ps/tests/machine/ollama_install_check.ps1
#>
[CmdletBinding()]
param([switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '../../..'
. (Join-Path $root 'ps/helpers.ps1')
Import-ScriptHelpers ci_defaults ollama_install

$script:passed = 0
$script:failed = 0
function case_([string]$label, $want, $got) {
    if ("$want" -eq "$got") { Write-Host "PASS  $label"; $script:passed++ }
    else { Write-Host "FAIL  $label`n      expected [$want]`n      got      [$got]"; $script:failed++ }
}
function version_of([string]$exe) {
    if (-not (Test-Path $exe)) { return '' }
    # The binary's own version, not a running server's.
    $v = ollama_installed_version $exe
    if ($v) { return $v }
    return ''
}

$asset = ollama_install_asset
if (-not $asset) { Write-Host "SKIP: no checkable Ollama zip for $($env:PROCESSOR_ARCHITECTURE)"; exit 2 }
$pinned = $env:CI_DEFAULT_OLLAMA_VERSION
$url = "https://github.com/ollama/ollama/releases/download/v$pinned/$asset"
try { Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing | Out-Null }
catch { Write-Host 'SKIP: the release cannot be reached from here'; exit 2 }
Write-Host "machine: $([System.Environment]::OSVersion.VersionString) $($env:PROCESSOR_ARCHITECTURE), PowerShell $($PSVersionTable.PSVersion); asset $asset; pinned $pinned"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ollama-check-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Write-Host "`n1. install the real release into an empty directory"
    $a = Join-Path $work 'a'
    $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing
    $mb = [math]::Round([double]($head.Headers['Content-Length'] | Select-Object -First 1) / 1e6)
    Write-Host "   downloading $url ($mb MB); this takes a while, and PowerShell shows no progress"
    $started = Get-Date
    $rc = ollama_install -Prefix $a
    $unpacked = [math]::Round((Get-ChildItem $a -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1e6)
    Write-Host "   took $([int]((Get-Date) - $started).TotalSeconds) s; $unpacked MB unpacked in $a"
    case_ 'install exits 0' 0 $rc
    case_ 'ollama.exe runs and reports the pinned version' $pinned (version_of (Join-Path $a 'ollama.exe'))
    case_ 'its libraries are in lib\ollama' $true ([bool](Get-ChildItem (Join-Path $a 'lib/ollama') -ErrorAction SilentlyContinue))

    # What case 1 installed, zipped again and served from a file: the remaining
    # cases need no second download.
    $www = Join-Path $work "www/v$pinned"
    New-Item -ItemType Directory -Path $www -Force | Out-Null
    $zip = Join-Path $www $asset
    Compress-Archive -Path (Join-Path $a '*') -DestinationPath $zip
    $good = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $env:OLLAMA_RELEASE_BASE_URL = ([System.Uri](Join-Path $work 'www')).AbsoluteUri
    $pinName = if ($asset -like '*arm64*') { 'CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64' } else { 'CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64' }

    Write-Host "`n2. a zip that does not match the pin"
    $b = Join-Path $work 'b'
    New-Item -ItemType Directory -Path (Join-Path $b 'lib/ollama') -Force | Out-Null
    Set-Content -Path (Join-Path $b 'lib/ollama/marker') -Value 'old'
    Set-Item -Path "env:$pinName" -Value ('0' * 64)
    $rc = ollama_install -Prefix $b
    case_ 'refused (1), the installed copy untouched' '1:old' "${rc}:$((Get-Content (Join-Path $b 'lib/ollama/marker') -ErrorAction SilentlyContinue))"

    Write-Host "`n3. upgrade an older install"
    Set-Item -Path "env:$pinName" -Value $good
    $c = Join-Path $work 'c'
    New-Item -ItemType Directory -Path (Join-Path $c 'lib/ollama') -Force | Out-Null
    Set-Content -Path (Join-Path $c 'lib/ollama/stale-library') -Value 'stale'
    Set-Content -Path (Join-Path $c 'app.txt') -Value 'not ours'
    $rc = ollama_install -Prefix $c -Force
    case_ 'upgraded to the pinned version' "0:$pinned" "${rc}:$(version_of (Join-Path $c 'ollama.exe'))"
    case_ 'the old libraries are gone, other files stay' 'False:True' "$(Test-Path (Join-Path $c 'lib/ollama/stale-library')):$(Test-Path (Join-Path $c 'app.txt'))"

    Write-Host "`nNot covered here, run by hand: winget (no -Prefix) installs or upgrades the Ollama it manages:"
    Write-Host '  .\ps\scripts\install_ollama.ps1 -Check ; .\ps\scripts\install_ollama.ps1'
} finally {
    Remove-Item Env:\OLLAMA_RELEASE_BASE_URL -ErrorAction SilentlyContinue
    if ($Keep) { Write-Host "kept: $work" } else { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

Write-Host "`nsummary: $script:passed passed, $script:failed failed (pinned $pinned)"
if ($script:failed -gt 0) { exit 1 }
exit 0

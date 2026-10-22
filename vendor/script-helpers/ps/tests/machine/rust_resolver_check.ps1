# SCRIPT: rust_resolver_check.ps1
# DESCRIPTION: Real-machine check of rust_toolchain_ci_uses: rustup's cargo first on PATH, the shadowing warning, and preflight.ps1 on a throwaway cargo project.
# USAGE: pwsh -NoProfile -File ps/tests/machine/rust_resolver_check.ps1 [-Keep] [-Help]
# PARAMETERS:
#   -Keep  Leave the throwaway directory for inspection (its path is printed).
#   -Help  Show this help message.
# EXIT_CODES:
#   0  every case passed (or -Help)
#   1  a case failed, or an unexpected error stopped the run
#   2  this machine cannot run the check (rustup is not installed)
# EXAMPLE: pwsh -NoProfile -File ps/tests/machine/rust_resolver_check.ps1
# ----------------------------------------------------
<#
.SYNOPSIS
Real-machine check of rust_toolchain_ci_uses: PowerShell counterpart to tests/machine/rust_resolver_check.sh.

.DESCRIPTION
Asks the installed rustup for its cargo, checks that rust_toolchain_ci_uses puts it
first on PATH, that a different cargo earlier on PATH draws the warning, that it
works with the caller's ErrorActionPreference set to Stop (the Windows PowerShell 5.1
native-stderr case), and runs preflight.ps1 on a throwaway cargo project.

Not part of the unit tests: it runs the real rustup and cargo. It never installs,
removes or switches a toolchain; one that is not installed is reported, not fetched.

Exit codes: 0 every case passed; 1 a case failed; 2 this machine cannot run the check (no rustup).

.PARAMETER Keep
Leave the throwaway directory for inspection (its path is printed).

.EXAMPLE
pwsh -NoProfile -File ps/tests/machine/rust_resolver_check.ps1
#>
[CmdletBinding()]
param([switch]$Keep, [switch]$Help)
# -Help: print the header above and stop, before anything runs.
if ($Help) { foreach ($l in Get-Content -LiteralPath $PSCommandPath) { if ($l -match '^#\s*-{4,}') { break }; $l -replace '^# ?', '' }; exit 0 }
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '../../..'
. (Join-Path $root 'ps/helpers.ps1')
Import-ScriptHelpers rust

if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { Write-Host 'SKIP: rustup is not installed'; exit 2 }

$script:passed = 0
$script:failed = 0
function case_([string]$label, $want, $got) {
    if ("$want" -eq "$got") { Write-Host "PASS  $label"; $script:passed++ }
    else { Write-Host "FAIL  $label`n      expected [$want]`n      got      [$got]"; $script:failed++ }
}
function rustup_cargo([string]$tc) {
    $ErrorActionPreference = 'Continue'
    $out = @(& rustup which --toolchain $tc cargo 2>$null) | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $out) { return "$out".Trim() }
    return ''
}
$sep = [System.IO.Path]::PathSeparator
function first_cargo {
    $c = Get-Command cargo -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return '' }
    if ($c.Path) { return $c.Path } else { return $c.Source }
}
# resolve <toolchain>: rust_toolchain_ci_uses under the current preference;
# returns "ok|first cargo|first PATH segment" and leaves warnings in $script:warn.
function resolve([string]$tc) {
    $script:warn = @()
    try {
        $all = @(rust_toolchain_ci_uses -Toolchain $tc 3>&1)
        $script:warn = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $ok = [bool]($all | Where-Object { $_ -is [bool] -and $_ })
        $r = if ($ok) { 'ok' } else { 'false' }
    } catch { $r = "threw: $($_.Exception.Message)" }
    return "$r|$(first_cargo)|$(($env:PATH -split [regex]::Escape([string]$sep))[0])"
}

$isWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$rustupVersion = (& { $ErrorActionPreference = 'Continue'; & rustup --version 2>$null } | Select-Object -First 1)
Write-Host "machine: $([System.Environment]::OSVersion.VersionString), PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)); $rustupVersion"
Write-Host "PATH cargo: $(first_cargo); RUST_TOOLCHAIN=$(if ($env:RUST_TOOLCHAIN) { $env:RUST_TOOLCHAIN } else { 'unset' })"

$savedPath = $env:PATH
$savedCI = $env:CI
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('rust-check-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $toolchains = @('stable')
    if ($env:RUST_TOOLCHAIN -and $env:RUST_TOOLCHAIN -ne 'stable') { $toolchains += $env:RUST_TOOLCHAIN }
    $n = 1
    foreach ($tc in $toolchains) {
        Write-Host "`n$n. rust_toolchain_ci_uses $tc"; $n++
        $want = rustup_cargo $tc
        if (-not $want) { case_ "${tc}: rustup has a cargo for it (rustup toolchain install $tc; not done here)" 'installed' 'missing'; continue }
        $env:PATH = $savedPath
        case_ "${tc}: rustup's cargo is first on PATH" "ok|$want|$(Split-Path -Parent $want)" (resolve $tc)
    }

    Write-Host "`n$n. a different cargo earlier on PATH"; $n++
    $want = rustup_cargo 'stable'
    $fake = Join-Path $work 'fake'
    New-Item -ItemType Directory -Path $fake | Out-Null
    if ($isWin) {
        Set-Content -Path (Join-Path $fake 'cargo.cmd') -Value '@echo cargo 0.0.0-fake' -Encoding ASCII
    } else {
        Set-Content -Path (Join-Path $fake 'cargo') -Value "#!/bin/sh`necho 'cargo 0.0.0-fake'" -Encoding ASCII
        & chmod +x (Join-Path $fake 'cargo')
    }
    $env:PATH = "$fake$sep$savedPath"
    case_ 'stable: rustup cargo wins over the fake' "ok|$want|$(Split-Path -Parent $want)" (resolve 'stable')
    case_ 'warning names the fake as what PATH offered' $true ([bool]($script:warn -match 'PATH offered cargo 0\.0\.0-fake'))

    Write-Host "`n$n. caller's ErrorActionPreference = 'Stop'"; $n++
    $under51 = $PSVersionTable.PSVersion.Major -eq 5
    Write-Host "   running under PowerShell $($PSVersionTable.PSVersion); Windows PowerShell 5.1: $(if ($under51) { 'yes' } else { 'no, so the 5.1 native-stderr path is not exercised' })"
    $env:PATH = $savedPath
    $ErrorActionPreference = 'Stop'
    case_ 'stable resolves with Stop in effect' "ok|$want|$(Split-Path -Parent $want)" (resolve 'stable')

    Write-Host "`n$n. preflight on a throwaway cargo project"
    $env:PATH = $savedPath
    $proj = Join-Path $work 'proj'
    New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force | Out-Null
    Set-Content -Path (Join-Path $proj 'Cargo.toml') -Value "[package]`nname = `"rcheck`"`nversion = `"0.1.0`"`nedition = `"2021`"`n`n[dependencies]" -Encoding ASCII
    Set-Content -Path (Join-Path $proj 'src/lib.rs') -Value "pub fn two() -> u32 { 2 }`n`n#[cfg(test)]`nmod tests {`n    #[test]`n    fn two() { assert_eq!(super::two(), 2); }`n}" -Encoding ASCII
    Remove-Item Env:\CI -ErrorAction SilentlyContinue
    $shell = (Get-Process -Id $PID).Path
    $log = Join-Path $work 'preflight.out'
    $ErrorActionPreference = 'Continue'
    & $shell -NoProfile -File (Join-Path $root 'ps/scripts/preflight.ps1') -Quick -SkipSecurity -Stack rust -Dir $proj *> $log
    $rc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $line = Get-Content $log | Where-Object { $_ -match '^(PASS|FAIL|SKIP)  rust' } | Select-Object -First 1
    Write-Host "   preflight rc ${rc}: $(if ($line) { $line } else { 'no rust line' })"
    $verdict = if ($rc -eq 0 -and $line -match '^(PASS|SKIP)') { 'ok' } else { 'bad' }
    if ($verdict -ne 'ok') { Get-Content $log -Tail 30 | ForEach-Object { Write-Host "      $_" } }
    case_ 'preflight reports PASS or SKIP for rust and exits 0' 'ok' $verdict

    Write-Host "`nNot covered here: a missing rustup (exit 2 above), a toolchain rustup has not installed,"
    Write-Host 'rustup directory overrides, and Windows PowerShell 5.1 unless this run says yes above.'
} finally {
    $env:PATH = $savedPath
    if ($null -ne $savedCI) { $env:CI = $savedCI }
    if ($Keep) { Write-Host "kept: $work" } else { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

Write-Host "`nsummary: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
exit 0

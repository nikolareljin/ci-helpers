# preflight.ps1 — run every check CI would have run, locally, before pushing.
# PowerShell companion to scripts/preflight.sh. Same detection rules, same
# flags, same exit codes, so `./dev preflight` behaves identically in either shell.
#
#   pwsh ps/scripts/preflight.ps1 [-Quick] [-Stack <name>] [-Docker]
#                                 [-SkipSecurity] [-List] [-Dir <path>]
#
# Exit codes:
#   0  Every check that ran passed.
#   1  At least one check failed.
#   2  Bad arguments, or an unknown -Stack.
#   3  No stack could be detected in this directory.
#
# A repo may pin exactly what runs with a `.preflight` file at its root: one
# "<stack> <dir>" per line, # comments allowed. When present it replaces
# autodetection.

param(
    [switch]$Quick,
    [string[]]$Stack = @(),
    [switch]$Docker,
    [switch]$SkipSecurity,
    [switch]$List,
    [string]$Dir
)

Set-StrictMode -Version Latest

if ($env:CI -eq 'true') {
    Write-Error 'This script is intended for local use only.'
    Write-Error 'In CI, run the checks directly — preflight exists to replace CI, not to run inside it.'
    exit 1
}

$SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) {
    $env:SCRIPT_HELPERS_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}
. (Join-Path $SCRIPT_HELPERS_DIR 'ps/helpers.ps1')
Import-ScriptHelpers logging

$KnownStacks = @('flutter','gradle','node','python','go','rust','php')
foreach ($s in $Stack) {
    if ($KnownStacks -notcontains $s) {
        log_error "preflight: unknown stack '$s'. Known: $($KnownStacks -join ' ')"
        exit 2
    }
}

if (-not $Dir) {
    $Dir = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if (-not $Dir) { $Dir = $PWD.Path }
}
if (-not (Test-Path $Dir -PathType Container)) { log_error "preflight: not a directory: $Dir"; exit 2 }
$ProjectDir = (Resolve-Path $Dir).Path
Set-Location $ProjectDir

# --- detection -------------------------------------------------------------
#
# A repo can be more than one stack at once, and in this fleet several are: an
# Android app under android/ plus a Python host under host/. Detecting a list of
# (stack, directory) pairs rather than one winner at the root is what lets this
# replace a multi-job CI workflow with one command.

$PrunedRe = '[\\/](node_modules|build|\.git|vendor|\.dart_tool|\.gradle|target|venv|\.venv)[\\/]'

function Get-DetectedStacks {
    $markers = @{
        'pubspec.yaml'     = 'flutter'
        'gradlew'          = 'gradle'
        'settings.gradle'  = 'gradle'
        'settings.gradle.kts' = 'gradle'
        'package.json'     = 'node'
        'pyproject.toml'   = 'python'
        'setup.py'         = 'python'
        'requirements.txt' = 'python'
        'go.mod'           = 'go'
        'Cargo.toml'       = 'rust'
        'composer.json'    = 'php'
    }
    $pairs = @()
    $flutterDirs = @()
    Get-ChildItem -Path . -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
        Where-Object { $markers.ContainsKey($_.Name) -and $_.FullName -notmatch $PrunedRe } |
        Sort-Object FullName |
        ForEach-Object {
            $rel = [System.IO.Path]::GetRelativePath($ProjectDir, $_.DirectoryName)
            if (-not $rel) { $rel = '.' }
            $rel = $rel -replace '\\','/'
            $st = $markers[$_.Name]
            $pairs += [PSCustomObject]@{ Stack = $st; Dir = $rel }
            if ($st -eq 'flutter') { $flutterDirs += $rel }
        }

    # Deduplicate, then drop two kinds of redundant project: a Gradle project
    # inside a Flutter app (built by `flutter build`, not a second Gradle pass),
    # and a same-stack project nested inside another (a Cargo workspace member is
    # built by its root).
    $unique = $pairs | Sort-Object Stack, Dir -Unique
    $kept = $unique | Where-Object {
        $p = $_
        if ($p.Stack -ne 'gradle') { return $true }
        foreach ($f in $flutterDirs) {
            if ($f -eq '.' -or $p.Dir -eq $f -or $p.Dir.StartsWith("$f/")) { return $false }
        }
        return $true
    }
    $kept | Where-Object {
        $p = $_
        foreach ($o in $kept) {
            if ($o.Stack -ne $p.Stack -or $o.Dir -eq $p.Dir) { continue }
            if ($o.Dir -eq '.' -or $p.Dir.StartsWith("$($o.Dir)/")) { return $false }
        }
        return $true
    }
}

function Get-ConfiguredStacks {
    $file = Join-Path $ProjectDir '.preflight'
    if (-not (Test-Path $file)) { return $null }
    $out = @()
    foreach ($line in (Get-Content $file)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+'
        if ($KnownStacks -notcontains $parts[0]) {
            log_error ".preflight: unknown stack '$($parts[0])'"
            exit 2
        }
        $d = if ($parts.Count -gt 1) { $parts[1] } else { '.' }
        $out += [PSCustomObject]@{ Stack = $parts[0]; Dir = $d }
    }
    return $out
}

$configured = Get-ConfiguredStacks
$Configured = [bool]$configured
$detected = if ($configured) { $configured } else { @(Get-DetectedStacks) }

if ($List) {
    if (-not $detected -or @($detected).Count -eq 0) {
        Write-Host "No stack detected in $ProjectDir"
        exit 3
    }
    $detected | ForEach-Object { Write-Output "$($_.Stack)`t$($_.Dir)" }
    exit 0
}

# -Stack filters the detected pairs rather than replacing them, so the directory
# a stack lives in is still discovered rather than assumed to be root.
$pairs = if ($Stack.Count -gt 0) {
    @($detected | Where-Object { $Stack -contains $_.Stack })
} else {
    @($detected)
}

if ($pairs.Count -eq 0) {
    if ($Stack.Count -gt 0) {
        log_error "preflight: -Stack $($Stack -join ' ') requested, but none was detected in $ProjectDir"
    } else {
        log_error "preflight: no stack detected in $ProjectDir"
        log_error 'Looked for: pubspec.yaml, gradlew, package.json, pyproject.toml, go.mod, Cargo.toml, composer.json'
        log_error 'Pass -Stack <name> to force one.'
    }
    exit 3
}

# --- step runner -----------------------------------------------------------
#
# Runs every check and reports all the failures rather than stopping at the
# first. A developer fixing three things wants to see three things.

$Results = New-Object System.Collections.Generic.List[string]
$script:Failed = $false

function Invoke-Step {
    param([string]$Label, [scriptblock]$Body)
    log_info "preflight: $Label"
    $ok = $false
    try { $ok = (& $Body) -ne $false -and $LASTEXITCODE -eq 0 } catch { $ok = $false }
    if ($ok) { $Results.Add("PASS  $Label") }
    else {
        $Results.Add("FAIL  $Label")
        $script:Failed = $true
        log_error "preflight: $Label FAILED"
    }
}

# A skip is not a pass — it is reported separately so an absent toolchain cannot
# look green.
function Add-Skip {
    param([string]$Label, [string]$Reason)
    $Results.Add("SKIP  $Label — $Reason")
    log_warn "preflight: skipping $Label — $Reason"
}

function Get-Label {
    param([string]$Stack, [string]$Dir)
    if ($Dir -eq '.') { return $Stack }
    return "$Stack ($Dir/)"
}

# --- per-stack checks ------------------------------------------------------

function Check-Flutter {
    param([string]$Dir)
    $name = Get-Label 'flutter' $Dir
    Import-ScriptHelpers flutter
    if (-not (flutter_available)) { Add-Skip $name 'flutter is not installed (set FLUTTER_ROOT)'; return }
    Invoke-Step "$name analyze" { flutter_analyze $Dir }
    Invoke-Step "$name test"    { flutter_test $Dir }
    if (-not $Quick) {
        Invoke-Step "$name build apk --debug" { flutter_build -Target apk -Dir $Dir -Mode debug }
    }
}

function Check-Gradle {
    param([string]$Dir)
    $name = Get-Label 'gradle' $Dir
    Import-ScriptHelpers gradle
    if (-not (gradle_available $Dir)) { Add-Skip $name 'no Gradle wrapper and no gradle on PATH'; return }
    $android = (Get-ChildItem -Path $Dir -Recurse -Depth 2 -Include 'build.gradle','build.gradle.kts' -ErrorAction SilentlyContinue |
                Select-String -Pattern 'com\.android\.(application|library)' -Quiet)
    $lintTask = if ($android) { 'lintDebug' } else { 'lint' }
    $testTask = if ($android) { 'testDebugUnitTest' } else { 'test' }
    $buildTask = if ($android) { 'assembleDebug' } else { 'build' }
    if (-not $Quick) { Invoke-Step "$name $lintTask" { gradle_run $Dir $lintTask } }
    Invoke-Step "$name $testTask" { gradle_run $Dir $testTask }
    if (-not $Quick) { Invoke-Step "$name $buildTask" { gradle_run $Dir $buildTask } }
}

function Check-Simple {
    param([string]$Stack, [string]$Dir, [string]$Tool, [string]$ScriptName)
    $name = Get-Label $Stack $Dir
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { Add-Skip $name "$Tool is not installed"; return }
    $script = Join-Path $SCRIPT_HELPERS_DIR "scripts/$ScriptName"
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Add-Skip $name "$ScriptName needs bash (Git for Windows ships it)"; return }
    $a = @($script); if ($Quick) { $a += '--quick' }
    Invoke-Step "$name lint + test" {
        Push-Location (Join-Path $ProjectDir $Dir)
        try { & $bash.Source @a } finally { Pop-Location }
    }
}

function Check-Security {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Add-Skip 'security scan' 'ci_security.sh needs bash (Git for Windows ships it)'; return }
    $script = Join-Path $SCRIPT_HELPERS_DIR 'scripts/ci_security.sh'
    if (-not (Test-Path $script)) { Add-Skip 'security scan' 'ci_security.sh not found'; return }
    $a = @($script, '--workdir', '.')
    if (-not $Docker) { $a += '--no-docker' }
    if (-not $Docker -and -not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        $a += '--skip-gitleaks'
        log_warn 'preflight: gitleaks is not installed — secret scanning is being skipped.'
        log_warn 'This is the one check the weekly scheduled sweep exists to backstop. Install gitleaks, or use -Docker.'
    }
    Invoke-Step 'security scan' { & $bash.Source @a }
}

# --- run -------------------------------------------------------------------

log_info "preflight: $ProjectDir"
$suffix = ''
if ($Configured) { $suffix += ' from .preflight' }
if ($Quick)      { $suffix += ' (quick)' }
if ($Docker)     { $suffix += ' (docker)' }
log_info "preflight: $($pairs.Count) project(s)$suffix"
$pairs | ForEach-Object { log_info "  - $(Get-Label $_.Stack $_.Dir)" }

foreach ($p in $pairs) {
    switch ($p.Stack) {
        'flutter' { Check-Flutter $p.Dir }
        'gradle'  { Check-Gradle  $p.Dir }
        'node'    { Check-Simple 'node'   $p.Dir 'npm'     'local_test_node.sh' }
        'python'  { Check-Simple 'python' $p.Dir 'python3' 'local_test_python.sh' }
        'go'      { Check-Simple 'go'     $p.Dir 'go'      'local_test_go.sh' }
        'rust'    { Check-Simple 'rust'   $p.Dir 'cargo'   'local_test_rust.sh' }
        'php'     { Check-Simple 'php'    $p.Dir 'php'     'local_test_php.sh' }
    }
}

if (-not $SkipSecurity) { Check-Security }

# --- summary ---------------------------------------------------------------

Write-Host ''
Write-Host 'preflight summary'
Write-Host '-----------------'
$Results | ForEach-Object { Write-Host $_ }
Write-Host ''

if (-not $script:Failed) {
    log_info 'preflight: all checks passed.'
    exit 0
}
log_error 'preflight: one or more checks failed. Fix them, or push with --no-verify if you know why.'
exit 1

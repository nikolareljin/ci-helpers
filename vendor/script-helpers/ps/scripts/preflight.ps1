# preflight.ps1 — run every check CI would have run, locally, before pushing.
# PowerShell companion to scripts/preflight.sh. Same detection rules, same
# flags, same exit codes, so `./dev preflight` behaves identically in either shell.
#
#   pwsh ps/scripts/preflight.ps1 [-Quick] [-Stack <name>] [-Docker]
#                                 [-SkipSecurity | -SecurityOnly] [-List] [-Dir <path>]
#
# -SecurityOnly runs only the secret / dependency scan (`./dev scan`); no stack
# is needed for it.
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
    [switch]$SecurityOnly,
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

# Two names, not $configured and $Configured: PowerShell variable names ignore
# case, so the flag overwrote the list with $true, and every repository with a
# .preflight threw on $true.Stack, checked nothing, and reported all checks passed.
$configuredStacks = @(Get-ConfiguredStacks | Where-Object { $_ })
$IsConfigured = $configuredStacks.Count -gt 0
$detected = if ($IsConfigured) { $configuredStacks } else { @(Get-DetectedStacks) }

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
# @(...) around the whole if: an if-expression unrolls an empty array to $null,
# and under StrictMode $null.Count throws, so the no-stack check below never ran.
$pairs = @(if ($Stack.Count -gt 0) {
    $detected | Where-Object { $Stack -contains $_.Stack }
} else {
    $detected
})

if ($SkipSecurity -and $SecurityOnly) {
    log_error 'preflight: -SkipSecurity and -SecurityOnly cannot be combined'
    exit 2
}

# The projects whose dependencies the security step audits, kept before
# -SecurityOnly empties $pairs; see SCAN_PAIRS in preflight.sh.
$scanPairs = @($pairs)

# The scan reads the repository, not a stack: none is needed for it.
if ($SecurityOnly) { $pairs = @() }
elseif ($pairs.Count -eq 0) {
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
    # --dir, not a cd: each runner resolves its directory against the repository
    # root, so a cd alone ran it on the wrong tree (preflight.sh's in_dir says so).
    $target = (Resolve-Path (Join-Path $ProjectDir $Dir)).Path
    $a = @($script, '--dir', $target); if ($Quick) { $a += '--quick' }
    $label = "$name lint + test"
    log_info "preflight: $label"
    # Exit 3: the runner could not check (nothing to test, or a tool is missing)
    # and wrote its one-line reason here. That is a SKIP, not a failure.
    $skipFile = New-TemporaryFile
    $env:PREFLIGHT_SKIP_FILE = $skipFile.FullName
    $rc = 1
    try { & $bash.Source @a; $rc = $LASTEXITCODE } catch { $rc = 1 }
    finally { Remove-Item Env:PREFLIGHT_SKIP_FILE -ErrorAction SilentlyContinue }
    $reason = Get-Content $skipFile.FullName -TotalCount 1 -ErrorAction SilentlyContinue
    Remove-Item $skipFile.FullName -ErrorAction SilentlyContinue
    if ($rc -eq 0) { $Results.Add("PASS  $label") }
    # Only with a reason: exit 3 alone can be a test command's own code.
    elseif ($rc -eq 3 -and $reason) { Add-Skip $label $reason }
    else {
        $Results.Add("FAIL  $label")
        $script:Failed = $true
        log_error "preflight: $label FAILED"
    }
}

# One ci_security.sh run as a step. Exit 3 with a reason in PREFLIGHT_SKIP_FILE
# means nothing it was asked for could run (a missing tool, no lockfile): SKIP.
function Invoke-ScanStep {
    param([string]$Label, [string]$BashPath, [string[]]$ScanArgs)
    log_info "preflight: $Label"
    $skipFile = New-TemporaryFile
    $env:PREFLIGHT_SKIP_FILE = $skipFile.FullName
    $rc = 1
    try { & $BashPath @ScanArgs; $rc = $LASTEXITCODE } catch { $rc = 1 }
    finally { Remove-Item Env:PREFLIGHT_SKIP_FILE -ErrorAction SilentlyContinue }
    $reason = Get-Content $skipFile.FullName -TotalCount 1 -ErrorAction SilentlyContinue
    Remove-Item $skipFile.FullName -ErrorAction SilentlyContinue
    if ($rc -eq 0) { $Results.Add("PASS  $Label") }
    elseif ($rc -eq 3 -and $reason) { Add-Skip $Label $reason }
    else {
        $Results.Add("FAIL  $Label")
        $script:Failed = $true
        log_error "preflight: $Label FAILED"
    }
}

function Check-Security {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Add-Skip 'security scan' 'ci_security.sh needs bash (Git for Windows ships it)'; return }
    $script = Join-Path $SCRIPT_HELPERS_DIR 'scripts/ci_security.sh'
    if (-not (Test-Path $script)) { Add-Skip 'security scan' 'ci_security.sh not found'; return }
    $common = @()
    if (-not $Docker) { $common += '--no-docker' }
    # `./dev scan` fails on findings; the pre-push run reports them without
    # blocking, as it always has, and says so in the summary.
    $suffix = ' (report only)'
    if ($SecurityOnly) { $common += '--fail-on-findings'; $suffix = '' }
    $repoArgs = @('--workdir', '.', '--skip-python', '--skip-node')
    $haveGitleaks = $true; $haveFoxguard = $true
    if (-not $Docker -and -not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        $repoArgs += '--skip-gitleaks'
        log_warn 'This is the one check the weekly scheduled sweep exists to backstop. Install gitleaks, or use -Docker.'
        # In the summary too: without it, "PASS  security scan" read as if secrets
        # had been scanned.
        Add-Skip 'gitleaks secret scan' 'gitleaks is not installed — install it, or use -Docker'
        $haveGitleaks = $false
    }
    # foxguard runs on the host in both modes; ci_security.sh knows where it looks.
    & $bash.Source $script --check-foxguard *> $null
    if ($LASTEXITCODE -ne 0) {
        Add-Skip 'foxguard code scan' "foxguard is not installed; bash $script --install-foxguard"
        $haveFoxguard = $false
    }
    # The repository-wide part: the secret scan and foxguard; see check_security
    # in preflight.sh.
    if ($haveGitleaks -or $haveFoxguard) {
        Invoke-ScanStep "security scan$suffix" $bash.Source (@($script) + $common + $repoArgs)
    }
    # The dependency audits, one step per project, in the project's directory.
    # Not with -Quick (the pre-push run); see check_security in preflight.sh.
    if ($Quick -and -not $SecurityOnly) {
        if (@($scanPairs | Where-Object { $_ -and ($_.Stack -eq 'python' -or $_.Stack -eq 'node') }).Count -gt 0) {
            Add-Skip 'dependency audits' 'not run with -Quick; ./dev scan runs them'
        }
        return
    }
    foreach ($p in $scanPairs) {
        if (-not $p) { continue }
        $target = Join-Path $ProjectDir $p.Dir
        switch ($p.Stack) {
            'python' { Invoke-ScanStep "$(Get-Label 'python' $p.Dir) dependency audit$suffix" $bash.Source (@($script) + $common + @('--workdir', $target, '--skip-node', '--skip-gitleaks', '--skip-foxguard')) }
            'node'   { Invoke-ScanStep "$(Get-Label 'node' $p.Dir) dependency audit$suffix" $bash.Source (@($script) + $common + @('--workdir', $target, '--skip-python', '--skip-gitleaks', '--skip-foxguard')) }
        }
    }
}

# --- run -------------------------------------------------------------------

log_info "preflight: $ProjectDir"
$suffix = ''
if ($IsConfigured) { $suffix += ' from .preflight' }
if ($Quick)      { $suffix += ' (quick)' }
if ($Docker)     { $suffix += ' (docker)' }
if ($SecurityOnly) { log_info 'preflight: security scan only' }
else {
    log_info "preflight: $($pairs.Count) project(s)$suffix"
    $pairs | ForEach-Object { log_info "  - $(Get-Label $_.Stack $_.Dir)" }
}

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

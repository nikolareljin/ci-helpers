# Gradle build helpers — PowerShell companion to lib/gradle.sh.
#
# Function names mirror the Bash module so one set of docs covers both.
#
# Windows difference: the wrapper is `gradlew.bat`, and NTFS has no executable
# bit, so presence is tested with Test-Path rather than an -x check.

function _Gradle_WrapperName {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return 'gradlew.bat' }
    return 'gradlew'
}

function gradle_available {
    param([string]$Dir = '.')
    if (Test-Path (Join-Path $Dir (_Gradle_WrapperName))) { return $true }
    return [bool](Get-Command gradle -ErrorAction SilentlyContinue)
}

# Prints the Gradle command to use for $Dir — the project's wrapper when present,
# otherwise a system gradle. Returns $null when neither is available.
function gradle_wrapper {
    param([string]$Dir = '.')
    $wrapper = Join-Path (Resolve-Path $Dir).Path (_Gradle_WrapperName)
    if (Test-Path $wrapper) { return $wrapper }
    $sys = Get-Command gradle -ErrorAction SilentlyContinue
    if ($sys) { return $sys.Source }
    if (Get-Command log_error -ErrorAction SilentlyContinue) {
        log_error "gradle_wrapper: no $(_Gradle_WrapperName) in $Dir and no gradle on PATH"
    }
    return $null
}

# Run Gradle tasks in $Dir. --no-daemon, because a daemon left running between
# local checks is a surprise memory cost on a laptop.
function gradle_run {
    param(
        [string]$Dir,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tasks
    )
    if (-not $Dir -or -not $Tasks -or $Tasks.Count -eq 0) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'gradle_run: need <dir> <task...>' }
        return $false
    }
    if (-not (Test-Path $Dir -PathType Container)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "gradle_run: not a directory: $Dir" }
        return $false
    }
    $cmd = gradle_wrapper $Dir
    if (-not $cmd) { return $false }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "gradle: $($Tasks -join ' ') (in $Dir)" }
    Push-Location $Dir
    try {
        & $cmd --no-daemon @Tasks
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function gradle_lint     { param([string]$Dir = '.') gradle_run $Dir 'lint' }
function gradle_test     { param([string]$Dir = '.') gradle_run $Dir 'test' }
function gradle_clean    { param([string]$Dir = '.') gradle_run $Dir 'clean' }

function gradle_assemble {
    param([string]$Dir = '.', [string]$Variant = 'Debug')
    gradle_run $Dir "assemble$Variant"
}

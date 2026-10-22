# Gradle build helpers - PowerShell companion to lib/gradle.sh.
#
# Function names mirror the Bash module so one set of docs covers both.
#
# Windows difference: the wrapper is `gradlew.bat`, and NTFS has no executable
# bit, so presence is tested with Test-Path rather than an -x check.

function _Gradle_WrapperName {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return 'gradlew.bat' }
    return 'gradlew'
}

# Usage: gradle_available [-Dir <dir>]
# Returns: $true when Dir has a wrapper or gradle is on PATH, else $false.
# Output: none.
function gradle_available {
    param([string]$Dir = '.')
    if (Test-Path (Join-Path $Dir (_Gradle_WrapperName))) { return $true }
    return [bool](Get-Command gradle -ErrorAction SilentlyContinue)
}

# Prints the Gradle command to use for $Dir - the project's wrapper when present,
# otherwise a system gradle. Returns $null when neither is available.
# Usage: gradle_wrapper [-Dir <dir>]
# Returns: the wrapper path, else the system gradle path; $null when neither.
# Output: stderr [ERROR] when neither is found; throws when Dir does not exist.
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
# Usage: gradle_run -Dir <dir> <task...>
# Runs the tasks with --no-daemon.
# Returns: $true when Gradle exits 0, else $false (also on bad arguments or no Gradle).
# Output: host Gradle's output; stderr [INFO] the tasks, [ERROR] on bad arguments.
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
        & $cmd --no-daemon @Tasks | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

# Usage: gradle_lint [-Dir <dir>]
# Returns: as gradle_run.
# Output: as gradle_run.
function gradle_lint     { param([string]$Dir = '.') gradle_run $Dir 'lint' }
# Usage: gradle_test [-Dir <dir>]
# Returns: as gradle_run.
# Output: as gradle_run.
function gradle_test     { param([string]$Dir = '.') gradle_run $Dir 'test' }
# Usage: gradle_clean [-Dir <dir>]
# Returns: as gradle_run.
# Output: as gradle_run.
function gradle_clean    { param([string]$Dir = '.') gradle_run $Dir 'clean' }

# Usage: gradle_assemble [-Dir <dir>] [-Variant <name>]   (default: Debug)
# Returns: as gradle_run.
# Output: as gradle_run.
function gradle_assemble {
    param([string]$Dir = '.', [string]$Variant = 'Debug')
    gradle_run $Dir "assemble$Variant"
}

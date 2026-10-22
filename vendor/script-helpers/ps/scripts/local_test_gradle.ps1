# SCRIPT: local_test_gradle.ps1
# DESCRIPTION: Lint, unit-test, and assemble a Gradle project on the host.
# USAGE: pwsh -File ps\scripts\local_test_gradle.ps1 [-Quick] [-Dir <path>] [-Android]
# PARAMETERS:
#   -Quick       Run unit tests only; skip lint and assemble.
#   -Dir <path>  Project directory with the Gradle wrapper (default: .).
#   -Android     Use Android task names. Autodetected when omitted.
#   -Help        Show this help message.
# EXIT_CODES:
#   0  Requested Gradle tasks passed.
#   1  A task failed, the directory is missing, or no Gradle is available.
# EXAMPLE: pwsh -File ps\scripts\local_test_gradle.ps1 -Quick
# ----------------------------------------------------

param(
    [switch]$Quick,
    [string]$Dir = '.',
    [switch]$Android,
    [switch]$Help
)
# -Help: print the header above and stop, before anything runs.
if ($Help) { foreach ($l in Get-Content -LiteralPath $PSCommandPath) { if ($l -match '^#\s*-{4,}') { break }; $l -replace '^# ?', '' }; exit 0 }

Set-StrictMode -Version Latest

$SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) {
    $env:SCRIPT_HELPERS_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}
. (Join-Path $SCRIPT_HELPERS_DIR 'ps/helpers.ps1')
Import-ScriptHelpers logging gradle

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $repoRoot) { $repoRoot = $PWD.Path }
$target = Join-Path $repoRoot $Dir
if (-not (Test-Path $target -PathType Container)) {
    log_error "[local-test-gradle] Directory not found: $target"
    exit 1
}

if (-not (gradle_available $target)) {
    log_error "[local-test-gradle] No Gradle wrapper in $Dir."
    log_error '[local-test-gradle] A system gradle would use a different version than the project pins.'
    exit 1
}

# Autodetect Android when the caller did not say. The Android plugin is applied
# in a build file; a plain JVM project has no lintDebug/assembleDebug tasks and
# would fail on them.
$isAndroid = $Android.IsPresent
if (-not $Android.IsPresent) {
    $isAndroid = [bool](Get-ChildItem -Path $target -Recurse -Depth 2 `
        -Include 'build.gradle','build.gradle.kts','libs.versions.toml' -ErrorAction SilentlyContinue |
        Select-String -Pattern 'com\.android\.(application|library)' -Quiet)
}

if ($isAndroid) {
    $lintTask = 'lintDebug'; $testTask = 'testDebugUnitTest'; $buildTask = 'assembleDebug'
} else {
    $lintTask = 'lint'; $testTask = 'test'; $buildTask = 'build'
}

$ok = $true
if (-not $Quick) {
    log_info "[local-test-gradle] gradlew $lintTask"
    if (-not (gradle_run $target $lintTask)) { $ok = $false }
}
if ($ok) {
    log_info "[local-test-gradle] gradlew $testTask"
    if (-not (gradle_run $target $testTask)) { $ok = $false }
}
if ($ok -and -not $Quick) {
    log_info "[local-test-gradle] gradlew $buildTask"
    if (-not (gradle_run $target $buildTask)) { $ok = $false }
}

if (-not $ok) { exit 1 }
log_info '[local-test-gradle] Done.'

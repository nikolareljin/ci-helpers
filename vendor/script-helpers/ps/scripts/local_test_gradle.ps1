# local_test_gradle.ps1 — lint, unit-test and assemble a Gradle project on the
# host. PowerShell companion to scripts/local_test_gradle.sh.
#
#   pwsh ps/scripts/local_test_gradle.ps1 [-Quick] [-Dir <path>] [-Android]
#
#   -Quick     Run unit tests only; skip lint and the assemble step.
#   -Dir       Project directory containing the Gradle wrapper (default: .).
#   -Android   Use the Android task names (lintDebug, testDebugUnitTest,
#              assembleDebug) instead of the plain JVM ones. Autodetected from
#              the presence of an Android plugin when omitted.

param(
    [switch]$Quick,
    [string]$Dir = '.',
    [switch]$Android
)

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

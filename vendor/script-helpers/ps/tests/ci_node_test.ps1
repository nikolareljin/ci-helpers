# Behaviour tests for ps/scripts/ci_node.ps1: the test step runs with CI=true
# unless CI is set, so a watch-mode runner (react-scripts test, vitest without run) exits
# instead of waiting for input; in Docker mode the container gets it too.
#
# Usage: pwsh -NoProfile -File ps/tests/ci_node_test.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script = Join-Path $root 'ps/scripts/ci_node.ps1'

$script:failures = 0
function note([string]$m) { Write-Host "[ci_node_test.ps1] $m" }
function fail([string]$m) { Write-Host "[ci_node_test.ps1][ERROR] $m"; $script:failures++ }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ci-node-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$app = Join-Path $tmp 'app'; New-Item -ItemType Directory -Force -Path $app | Out-Null
$log = Join-Path $tmp 'ci.log'
# The test command: a script that records the CI it was given.
$rec = Join-Path $tmp 'rec.ps1'
Set-Content -Path $rec -Value 'Add-Content -Path $env:CI_TEST_LOG -Value "CI=$env:CI"'

# ci_node.ps1 refuses CI=true, which a CI runner sets; each run clears it.
$savedCi = $env:CI; $savedPath = $env:PATH
$env:CI_TEST_LOG = $log
function run_ci_node([string]$ci, [string]$extra) {
    if (Test-Path $log) { Remove-Item $log }
    $env:CI = $ci
    $cmd = "& '$script' -Workdir '$app' -NoInstall -SkipLint -SkipBuild -TestCmd 'pwsh','-NoProfile','-File','$rec' $extra"
    & pwsh -NoProfile -Command $cmd 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    $env:CI = $savedCi
    $got = if (Test-Path $log) { (Get-Content -Raw $log).Trim() } else { '' }
    return @($rc, $got)
}
function expect([string]$label, $result, [string]$want) {
    if ($result[0] -eq 0 -and $result[1] -eq $want) { note "PASS: $label" }
    else { fail "$label`: exit $($result[0]), log '$($result[1])', want '$want'" }
}

try {
    expect 'CI unset: the test step gets CI=true' (run_ci_node '' '') 'CI=true'
    expect 'a CI the caller set is kept' (run_ci_node '1' '') 'CI=1'

    # Docker mode: a stub docker answers `info` and records `run`. The stub is
    # a shell script, so this case runs where one can be executed.
    if ($IsWindows) {
        note 'SKIP docker case: the stub docker is a shell script'
    } else {
        $bin = Join-Path $tmp 'bin'; New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $docker = Join-Path $bin 'docker'
        Set-Content -Path $docker -Value "#!/usr/bin/env bash`n[ `"`$1`" = run ] && printf '%s\n' `"`$*`" >> '$log'`nexit 0`n"
        & chmod +x $docker
        $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$savedPath"
        try {
            if (Test-Path $log) { Remove-Item $log }
            $env:CI = ''
            & pwsh -NoProfile -Command "& '$script' -Workdir '$app' -NoInstall -SkipLint -SkipBuild -UseDocker -Image 'node:test'" 2>&1 | Out-Null
            $rc = $LASTEXITCODE
            $env:CI = $savedCi
            $got = if (Test-Path $log) { (Get-Content -Raw $log).Trim() } else { '' }
            if ($rc -eq 0 -and $got -match '(^| )-e CI ') { note 'PASS: Docker mode passes CI to the container' }
            else { fail "Docker mode: exit $rc, docker got '$got', want '-e CI'" }
        } finally { $env:PATH = $savedPath }
    }
} finally {
    $env:CI = $savedCi; $env:PATH = $savedPath
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { note "$($script:failures) FAILURE(S)"; exit 1 }
note 'all passed'

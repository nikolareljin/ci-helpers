# Behaviour tests for ps/scripts/ci_python.ps1: requirements-dev.txt installs
# after requirements.txt, so a project that keeps pytest there is tested
# instead of failing with "No module named pytest".
#
# Usage: pwsh -NoProfile -File ps/tests/ci_python_test.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script = Join-Path $root 'ps/scripts/ci_python.ps1'

$script:failures = 0
function note([string]$m) { Write-Host "[ci_python_test.ps1] $m" }
function fail([string]$m) { Write-Host "[ci_python_test.ps1][ERROR] $m"; $script:failures++ }

# Docker mode with a stub docker that answers `info` and records `run`. The
# stub is a shell script, so this runs where one can be executed.
if ($IsWindows) { note 'SKIP: the stub docker is a shell script'; exit 0 }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ci-python-test-" + [guid]::NewGuid())
$app = Join-Path $tmp 'app'; $bin = Join-Path $tmp 'bin'
New-Item -ItemType Directory -Force -Path $app, $bin | Out-Null
$log = Join-Path $tmp 'docker.log'
Set-Content -Path (Join-Path $app 'requirements.txt') -Value 'requests'
Set-Content -Path (Join-Path $app 'requirements-dev.txt') -Value 'pytest'
$docker = Join-Path $bin 'docker'
Set-Content -Path $docker -Value "#!/usr/bin/env bash`n[ `"`$1`" = run ] && printf '%s\n' `"`$*`" >> '$log'`nexit 0`n"
& chmod +x $docker

# ci_python.ps1 refuses CI=true, which a CI runner sets; the run clears it.
$savedCi = $env:CI; $savedPath = $env:PATH
try {
    $env:CI = ''
    $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$savedPath"
    & pwsh -NoProfile -Command "& '$script' -Workdir '$app' -UseDocker -Image 'python:test' -SkipTest" 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    $got = if (Test-Path $log) { @(Get-Content $log) } else { @() }
    $installs = @($got | Where-Object { $_ -match 'pip install -r ' } | ForEach-Object { ($_ -split 'pip install -r ')[1].Trim() })
    if ($rc -eq 0 -and ($installs -join ',') -eq 'requirements.txt,requirements-dev.txt') {
        note 'PASS: requirements-dev.txt installs after requirements.txt'
    } else {
        fail "exit $rc, installs '$($installs -join ',')', want 'requirements.txt,requirements-dev.txt'"
    }
} finally {
    $env:CI = $savedCi; $env:PATH = $savedPath
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { note "$($script:failures) FAILURE(S)"; exit 1 }
note 'all passed'

# Behaviour tests for ps/scripts/preflight.ps1.
#
# $configured and $Configured were one variable (PowerShell names ignore case),
# so the flag overwrote the .preflight list with $true: every repository with a
# .preflight threw on $true.Stack, checked nothing, and printed "all checks
# passed" with exit 0. -SecurityOnly also audited dependencies only at the root.
# Stub tools (sh scripts) record where they ran, so no real audit runs.
#
# Usage: pwsh -NoProfile -File ps/tests/preflight_test.ps1
$ErrorActionPreference = 'Stop'
$preflight = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'scripts') 'preflight.ps1'

$script:failures = 0
function note([string]$m)  { Write-Host "[preflight_test.ps1] $m" }
function fail([string]$m)  { Write-Host "[preflight_test.ps1][ERROR] $m"; $script:failures++ }

if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Get-Command bash -ErrorAction SilentlyContinue)) {
    note 'SKIP: git and bash are needed'
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("preflight-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$bin = Join-Path $tmp 'bin'
New-Item -ItemType Directory -Path $bin | Out-Null
$log = Join-Path $tmp 'audit.log'
foreach ($t in 'pip-audit', 'safety', 'bandit', 'npm', 'gitleaks') {
    $f = Join-Path $bin $t
    Set-Content -Path $f -Value "#!/bin/sh`necho `"$t `$(basename `"`$(pwd -P)`") `$*`" >> '$log'`nexit 0" -Encoding ascii
    & chmod +x $f
}
$savedPath = $env:PATH; $savedCi = $env:CI; $savedCache = $env:XDG_CACHE_HOME

# preflight refuses to run under CI=true; the stubs come first on PATH.
function Invoke-Preflight([string]$repo, [string[]]$argv) {
    Push-Location $repo
    try {
        $env:CI = ''; $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$savedPath"
        $env:XDG_CACHE_HOME = Join-Path $tmp 'cache'
        $out = & pwsh -NoProfile -File $preflight @argv 2>&1 | Out-String
        return @{ Out = $out; Rc = $LASTEXITCODE }
    } finally {
        Pop-Location
        $env:PATH = $savedPath; $env:CI = $savedCi; $env:XDG_CACHE_HOME = $savedCache
    }
}
function New-Repo([string]$name) {
    $r = Join-Path $tmp $name
    New-Item -ItemType Directory -Path $r | Out-Null
    & git -C $r init -q
    return $r
}

try {
    # 1. A .preflight is read: -List prints its projects.
    $r = New-Repo 'cfg'
    New-Item -ItemType Directory -Path (Join-Path $r 'web') | Out-Null
    Set-Content -Path (Join-Path $r 'web/package.json') -Value '{"name":"w","version":"1.0.0"}'
    Set-Content -Path (Join-Path $r '.preflight') -Value 'node web'
    $res = Invoke-Preflight $r @('-List')
    if ($res.Rc -eq 0 -and $res.Out -match "node`tweb") { note '.preflight: -List prints its project' }
    else { fail ".preflight -List: rc=$($res.Rc) out=$($res.Out)" }

    # 2. ...and run: the project is checked, not an exception followed by "all checks passed".
    $res = Invoke-Preflight $r @('-Quick', '-SkipSecurity')
    if ($res.Out -match 'from \.preflight' -and $res.Out -match 'node \(web/\)' -and $res.Out -notmatch 'cannot be found') {
        note '.preflight: its project is checked'
    } else { fail ".preflight run: rc=$($res.Rc) out=$($res.Out)" }

    # 3. -SecurityOnly audits each project in its own directory.
    $r = New-Repo 'audits'
    New-Item -ItemType Directory -Path (Join-Path $r 'backend'), (Join-Path $r 'frontend') | Out-Null
    Set-Content -Path (Join-Path $r 'backend/pyproject.toml') -Value "[project]`nname = `"b`"`nversion = `"0.1.0`""
    Set-Content -Path (Join-Path $r 'frontend/package.json') -Value '{"name":"f","version":"1.0.0"}'
    Set-Content -Path (Join-Path $r 'frontend/package-lock.json') -Value '{}'
    Set-Content -Path (Join-Path $r '.preflight') -Value "python backend`nnode frontend"
    Set-Content -Path $log -Value ''
    $res = Invoke-Preflight $r @('-SecurityOnly')
    $calls = Get-Content $log -Raw
    if ($res.Rc -eq 0 -and $res.Out -match 'PASS  python \(backend/\) dependency audit' -and $res.Out -match 'PASS  node \(frontend/\) dependency audit' `
        -and $calls -match 'pip-audit backend \.' -and $calls -match 'npm frontend audit') {
        note '-SecurityOnly: pip-audit in backend/, npm audit in frontend/'
    } else { fail "audits: rc=$($res.Rc) calls=$calls out=$($res.Out)" }

    # 4. No lockfile: that audit is a SKIP with its reason.
    Remove-Item (Join-Path $r 'frontend/package-lock.json')
    $res = Invoke-Preflight $r @('-SecurityOnly')
    if ($res.Out -match 'SKIP  node \(frontend/\) dependency audit .* No package-lock\.json') { note 'no lockfile: SKIP with the reason' }
    else { fail "no lockfile: out=$($res.Out)" }

    # 4b. Without .preflight, detected projects are audited the same way.
    Set-Content -Path (Join-Path $r 'frontend/package-lock.json') -Value '{}'
    Remove-Item -Force (Join-Path $r '.preflight')
    Set-Content -Path $log -Value ''
    $res = Invoke-Preflight $r @('-SecurityOnly')
    $calls = Get-Content $log -Raw
    if ($res.Out -match 'PASS  python \(backend/\) dependency audit' -and $res.Out -match 'PASS  node \(frontend/\) dependency audit' `
        -and $calls -match 'pip-audit backend \.' -and $calls -match 'npm frontend audit') {
        note 'detected projects (no .preflight): audited in their directories'
    } else { fail "detected: calls=$calls out=$($res.Out)" }

    # 5. -Quick (the pre-push run) does not audit; one SKIP line says ./dev scan does.
    Set-Content -Path (Join-Path $r 'frontend/package-lock.json') -Value '{}'
    Set-Content -Path $log -Value ''
    $res = Invoke-Preflight $r @('-Quick')
    $calls = Get-Content $log -Raw
    if ($res.Out -match 'SKIP  dependency audits .* not run with -Quick' -and $calls -notmatch 'audit --audit-level' -and $calls -notmatch 'pip-audit') {
        note '-Quick: no audit, one SKIP line'
    } else { fail "quick: calls=$calls out=$($res.Out)" }
}
finally {
    Remove-Item -Recurse -Force $tmp
}

if ($script:failures -eq 0) { note 'ALL PASSED'; exit 0 }
note "$($script:failures) FAILURE(S)"
exit 1

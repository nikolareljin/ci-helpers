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
    # `gitleaks version` answers with a version far above any pin: preflight
    # passes over a gitleaks on PATH that is older than the pinned one.
    Set-Content -Path $f -Value "#!/bin/sh`nif [ `"$t `$1`" = 'gitleaks version' ]; then echo 999.0.0; exit 0; fi`necho `"$t `$(basename `"`$(pwd -P)`") `$*`" >> '$log'`nexit 0" -Encoding ascii
    & chmod +x $f
}
$savedPath = $env:PATH; $savedCi = $env:CI; $savedCache = $env:XDG_CACHE_HOME
$savedNoInstall = $env:PREFLIGHT_NO_INSTALL
# Nothing is downloaded unless a case asks for it (case 8, with a stub curl).
$script:noInstall = '1'

# preflight refuses to run under CI=true; the stubs come first on PATH.
function Invoke-Preflight([string]$repo, [string[]]$argv) {
    Push-Location $repo
    try {
        $env:CI = ''; $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$savedPath"
        $env:XDG_CACHE_HOME = Join-Path $tmp 'cache'
        $env:PREFLIGHT_NO_INSTALL = $script:noInstall
        $out = & pwsh -NoProfile -File $preflight @argv 2>&1 | Out-String
        return @{ Out = $out; Rc = $LASTEXITCODE }
    } finally {
        Pop-Location
        $env:PATH = $savedPath; $env:CI = $savedCi; $env:XDG_CACHE_HOME = $savedCache
        if ($null -eq $savedNoInstall) { Remove-Item Env:PREFLIGHT_NO_INSTALL -ErrorAction SilentlyContinue } else { $env:PREFLIGHT_NO_INSTALL = $savedNoInstall }
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

    # 6. Rust follows preflight.sh: without rustup, a PATH cargo is not used.
    # The real runner compiles with rustup's toolchain, so that is a SKIP
    # naming the remedy, not a failed step.
    $r = New-Repo 'rusty'
    Set-Content -Path (Join-Path $r 'Cargo.toml') -Value "[package]`nname = `"r`"`nversion = `"0.1.0`""
    Set-Content -Path (Join-Path $bin 'cargo') -Value "#!/bin/sh`nexit 0" -Encoding ascii
    & chmod +x (Join-Path $bin 'cargo')
    $sep = [System.IO.Path]::PathSeparator
    $noRustup = ($savedPath -split [regex]::Escape([string]$sep) | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'rustup')) }) -join $sep
    $keep = $savedPath; $savedPath = $noRustup
    try {
        $res = Invoke-Preflight $r @('-Quick', '-SkipSecurity')
        if ($res.Out -match 'SKIP  rust .*rustup is not installed.*PREFLIGHT_RUST_ANY_CARGO' -and $res.Out -notmatch 'FAIL') {
            note 'rust without rustup: SKIP naming rustup, PATH cargo not used'
        } else { fail "rust without rustup: rc=$($res.Rc) out=$($res.Out)" }
    } finally { $savedPath = $keep }

    # 7. A rustup that fails is no toolchain, even when it printed a path.
    Set-Content -Path (Join-Path $bin 'rustup') -Value "#!/bin/sh`necho '$(Join-Path $bin 'cargo')'`nexit 1" -Encoding ascii
    & chmod +x (Join-Path $bin 'rustup')
    $res = Invoke-Preflight $r @('-Quick', '-SkipSecurity')
    if ($res.Out -match "SKIP  rust .*rustup has no cargo for 'stable'" -and $res.Out -notmatch 'FAIL') {
        note 'rust with a failing rustup: SKIP naming the toolchain'
    } else { fail "rust with a failing rustup: rc=$($res.Rc) out=$($res.Out)" }
    Remove-Item (Join-Path $bin 'rustup')

    # 8. As preflight.sh: a gitleaks on PATH older than the pin is replaced by
    #    the pinned release (a stub curl serves a bad archive, so the install
    #    fails its checksum and nothing reaches the network); not with
    #    PREFLIGHT_NO_INSTALL=1.
    $r = New-Repo 'oldgl'
    $curlLog = Join-Path $tmp 'curl.log'
    Set-Content -Path (Join-Path $bin 'gitleaks') -Value "#!/bin/sh`nif [ `"`$1`" = version ]; then echo 1.0.0; fi`nexit 0" -Encoding ascii
    Set-Content -Path (Join-Path $bin 'curl') -Value "#!/bin/sh`nout=''; url=''`nwhile [ `$# -gt 0 ]; do case `"`$1`" in -o) out=`"`$2`"; shift 2;; -*) shift;; *) url=`"`$1`"; shift;; esac; done`necho `"`$url`" >> '$curlLog'`necho junk > `"`$out`"" -Encoding ascii
    & chmod +x (Join-Path $bin 'gitleaks') (Join-Path $bin 'curl')
    try {
        $script:noInstall = ''
        $res = Invoke-Preflight $r @('-SecurityOnly')
        $urls = Get-Content $curlLog -Raw -ErrorAction SilentlyContinue
        if ($urls -match 'gitleaks/releases/download/' -and $res.Out -match 'older than the minimum') {
            note 'older gitleaks on PATH: the pinned release is installed'
        } else { fail "older gitleaks install: urls=$urls out=$($res.Out)" }
        Remove-Item $curlLog -ErrorAction SilentlyContinue
        $script:noInstall = '1'
        $res = Invoke-Preflight $r @('-SecurityOnly')
        if (-not (Test-Path $curlLog) -and $res.Out -match 'SKIP  gitleaks secret scan') {
            note 'PREFLIGHT_NO_INSTALL=1: nothing downloaded, SKIP reported'
        } else { fail "PREFLIGHT_NO_INSTALL: out=$($res.Out)" }
    } finally {
        $script:noInstall = '1'
        Remove-Item (Join-Path $bin 'curl')
    }
}
finally {
    Remove-Item -Recurse -Force $tmp
}

if ($script:failures -eq 0) { note 'ALL PASSED'; exit 0 }
note "$($script:failures) FAILURE(S)"
exit 1

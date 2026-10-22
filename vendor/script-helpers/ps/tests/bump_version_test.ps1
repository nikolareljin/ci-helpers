# Behaviour tests for ps/scripts/bump_version.ps1 in a project that vendors
# script-helpers as a submodule: the project's VERSION is bumped, the vendored
# copy's never. The default used to resolve inside the vendored copy.
#
# Usage: pwsh -NoProfile -File ps/tests/bump_version_test.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

$script:failures = 0
function note([string]$m) { Write-Host "[bump_version_test.ps1] $m" }
function fail([string]$m) { Write-Host "[bump_version_test.ps1][ERROR] $m"; $script:failures++ }
function check([string]$label, [string]$file, [string]$want) {
    $got = if (Test-Path $file) { (Get-Content -Raw $file).Trim() } else { '' }
    if ($got -eq $want) { note "PASS: $label" } else { fail "$label`: $file is '$got', want '$want'" }
}
function git_q { $ErrorActionPreference = 'Continue'; & git @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $args failed" } }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { note 'SKIP: git not available'; exit 0 }
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.com'
$env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.com'
$env:GIT_CONFIG_NOSYSTEM = '1'
foreach ($v in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
Remove-Item Env:SCRIPT_HELPERS_DIR -ErrorAction SilentlyContinue

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bump-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$here = $PWD.Path
try {
    $helpers = Join-Path $tmp 'helpers'
    New-Item -ItemType Directory -Path $helpers | Out-Null
    foreach ($d in 'helpers.sh', 'lib', 'ps') { Copy-Item -Recurse (Join-Path $root $d) $helpers }
    Set-Content -Path (Join-Path $helpers 'VERSION') -Value '0.55.0'
    git_q -C $helpers init -q; git_q -C $helpers add -A; git_q -C $helpers commit -qm helpers

    $proj = Join-Path $tmp 'proj'
    New-Item -ItemType Directory -Path (Join-Path $proj 'sub') | Out-Null
    git_q -C $proj init -q
    Set-Content -Path (Join-Path $proj 'VERSION') -Value '1.0.0'
    git_q -C $proj -c protocol.file.allow=always submodule add -q $helpers scripts/script-helpers
    $vend = Join-Path $proj 'scripts/script-helpers'
    $bump = Join-Path $vend 'ps/scripts/bump_version.ps1'

    Set-Location $proj; & $bump patch | Out-Null
    check 'from the project root, the project VERSION is bumped' (Join-Path $proj 'VERSION') '1.0.1'
    check 'from the project root, the vendored VERSION is untouched' (Join-Path $vend 'VERSION') '0.55.0'

    Set-Location $vend; & $bump minor | Out-Null
    check 'from inside the vendored copy, the project VERSION is bumped' (Join-Path $proj 'VERSION') '1.1.0'
    check 'from inside the vendored copy, its own VERSION is untouched' (Join-Path $vend 'VERSION') '0.55.0'

    Set-Location (Join-Path $proj 'sub')
    Set-Content -Path 'V' -Value '2.0.0'
    & $bump major -File V | Out-Null
    check 'a relative -File is relative to the cwd' (Join-Path $proj 'sub/V') '3.0.0'
}
catch { fail "unexpected error: $_" }
finally {
    Set-Location $here
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:failures -gt 0) { note "$($script:failures) FAILURE(S)"; exit 1 }
note 'ALL PASSED'

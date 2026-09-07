# Locate and load script-helpers — PowerShell companion to _bootstrap.sh.
#
# COPIED into a consumer repo, not dot-sourced from the library, because finding
# the library is the thing it does.
#
# Sets $DEV_REPO_ROOT and $env:SCRIPT_HELPERS_DIR, then dot-sources ps/helpers.ps1.

$DEV_SCRIPT_DIR = $PSScriptRoot
$DEV_REPO_ROOT = (& git -C $DEV_SCRIPT_DIR rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $DEV_REPO_ROOT) {
    $DEV_REPO_ROOT = (Resolve-Path (Join-Path $DEV_SCRIPT_DIR '..')).Path
}

# The canonical path is scripts/script-helpers. The others are the layouts that
# exist in the fleet today and are being migrated away from; they stay here so a
# repo mid-migration is not broken by the order of its PRs.
$_devHelperCandidates = @(
    (Join-Path $DEV_REPO_ROOT 'scripts/script-helpers'),
    (Join-Path $DEV_REPO_ROOT 'vendor/script-helpers'),
    (Join-Path $DEV_REPO_ROOT 'script-helpers'),
    (Join-Path $DEV_REPO_ROOT 'scripts/helpers'),
    (Join-Path $DEV_REPO_ROOT 'tools/script-helpers'),
    (Join-Path $DEV_REPO_ROOT '.script-helpers'),
    (Join-Path $DEV_REPO_ROOT 'externals/script-helpers')
)

function Find-ScriptHelpers {
    if ($env:SCRIPT_HELPERS_DIR -and (Test-Path (Join-Path $env:SCRIPT_HELPERS_DIR 'ps/helpers.ps1'))) {
        return $env:SCRIPT_HELPERS_DIR
    }
    foreach ($c in $_devHelperCandidates) {
        if (Test-Path (Join-Path $c 'ps/helpers.ps1')) { return $c }
    }
    return $null
}

# Self-heal an uninitialized submodule. A fresh `git clone` without --recursive
# leaves the directory present but empty, which is the single most common
# "nothing works" report in this fleet.
function Initialize-ScriptHelpers {
    foreach ($c in $_devHelperCandidates) {
        if (-not (Test-Path $c -PathType Container)) { continue }
        $rel = $c.Substring($DEV_REPO_ROOT.Length).TrimStart('\','/')
        Write-Host "[dev] initializing script-helpers submodule at $rel"
        & git -C $DEV_REPO_ROOT submodule update --init --recursive $rel
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

$helpers = Find-ScriptHelpers
if (-not $helpers) {
    Initialize-ScriptHelpers | Out-Null
    $helpers = Find-ScriptHelpers
}
if (-not $helpers) {
    Write-Error @'
[dev] script-helpers not found.

Expected it at scripts/script-helpers. Fix with:

  git submodule update --init --recursive

If this repo has never had the submodule:

  git submodule add -b production https://github.com/nikolareljin/script-helpers.git scripts/script-helpers
'@
    exit 1
}

$env:SCRIPT_HELPERS_DIR = $helpers
. (Join-Path $helpers 'ps/helpers.ps1')

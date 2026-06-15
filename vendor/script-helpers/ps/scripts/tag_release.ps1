# SCRIPT: tag_release.ps1
# DESCRIPTION: Create an annotated git tag from the current VERSION file and push it.
# USAGE: ps\scripts\tag_release.ps1 [-File <path>] [-Remote <remote>] [-DryRun]
# PARAMETERS:
#   -File <path>     Path to VERSION file (default: VERSION in project root).
#   -Remote <name>   Git remote to push to (default: origin).
#   -DryRun          Print the tag that would be created without actually tagging.
#   -Help            Show this help message.
# ----------------------------------------------------
param(
    [string] $File    = 'VERSION',
    [string] $Remote  = 'origin',
    [switch] $DryRun,
    [switch] $Help
)

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging version env

if ($Help) { display_help $PSCommandPath; exit 0 }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error "git not found on PATH."; exit 1 }
git rev-parse --show-toplevel 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not inside a git repository."; exit 1 }

if (-not [System.IO.Path]::IsPathRooted($File)) {
    $gitRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitRoot) { $File = Join-Path $gitRoot.Trim() $File }
}
if (-not (Test-Path $File)) { Write-Error "VERSION file not found: $File"; exit 1 }
$version = (Get-Content $File -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { Write-Error "Invalid version in $File: $version"; exit 1 }

log_info "Version: $version"

if ($DryRun) {
    print_info "Dry run — would create tag: $version"
    exit 0
}

$existing = git tag -l $version
if ($existing) { Write-Error "Tag '$version' already exists. Bump VERSION first."; exit 1 }
git tag -a $version -m "Release $version"
if ($LASTEXITCODE -ne 0) { Write-Error "git tag failed."; exit 1 }
git push $Remote $version
if ($LASTEXITCODE -ne 0) { Write-Error "git push tag failed."; exit 1 }
print_success "Tagged and pushed: $version"

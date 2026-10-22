# SCRIPT: bump_version.ps1
# DESCRIPTION: Bump the semantic version in the VERSION file.
# USAGE: pwsh -File ps\scripts\bump_version.ps1 <major|minor|patch> [-File <path>]
# PARAMETERS:
#   BumpType         Required. One of: major, minor, patch.
#   -File <path>     Path to the VERSION file; relative to the current directory.
#                    Default: VERSION at the project root (top of the git work
#                    tree holding the cwd, the superproject when run inside a
#                    vendored script-helpers submodule, else the cwd).
#   -Help            Show this help message.
# EXIT_CODES:
#   0  Version updated.
#   1  Bad arguments or version update failed.
# EXAMPLE: pwsh -File ps\scripts\bump_version.ps1 patch
# ----------------------------------------------------
param(
    [Parameter(Position=0)]
    [ValidateSet('major','minor','patch')]
    [string] $BumpType,
    [string] $File = '',
    [switch] $Help
)

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging version env

if ($Help) { display_help $PSCommandPath; exit 0 }
if (-not $BumpType) { display_help $PSCommandPath; exit 1 }

version_bump -BumpType $BumpType -VersionFile $File

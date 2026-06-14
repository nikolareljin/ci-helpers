# SCRIPT: ci_go.ps1
# DESCRIPTION: Run Go CI steps (vet, test) on Windows.
# USAGE: ps\scripts\ci_go.ps1 [-Workdir <path>] [-Quick] [-Module <path>]
# PARAMETERS:
#   -Workdir <path>   Working directory (default: current dir).
#   -Quick            Run go vet only, skip tests.
#   -Module <path>    Specific module path to test.
#   -UseDocker        Run inside Docker Desktop instead of natively.
#   -Image <img>      Docker image override (requires -UseDocker).
#   -Help             Show this help message.
# ----------------------------------------------------
param(
    [string] $Workdir  = '.',
    [switch] $Quick,
    [string] $Module   = './...',
    [switch] $UseDocker,
    [string] $Image    = '',
    [switch] $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging docker ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = if ([System.IO.Path]::IsPathRooted($Workdir)) { $Workdir } else { Join-Path $PWD.Path $Workdir }
if (-not (Test-Path $absWorkdir -PathType Container)) { Write-Error "Working directory not found: $absWorkdir"; exit 1 }

if ($UseDocker) {
    if (-not (check_docker)) { exit 1 }
    $img  = if ($Image) { $Image } elseif ($env:CI_GO_IMAGE) { $env:CI_GO_IMAGE } else { 'golang:latest' }
    $volArgs = @('run', '--rm', '-v', "${absWorkdir}:/work", '-w', '/work', $img)
    log_info "go vet $Module"
    docker @volArgs go vet $Module
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not $Quick) {
        log_info "go test $Module"
        docker @volArgs go test $Module
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} else {
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Write-Error "go not found on PATH."; exit 1 }
    Push-Location $absWorkdir
    try {
        log_info "go vet $Module"
        go vet $Module
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if (-not $Quick) {
            log_info "go test $Module"
            go test $Module
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    } finally { Pop-Location }
}
print_success "Go CI complete."

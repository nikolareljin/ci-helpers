# SCRIPT: ci_python.ps1
# DESCRIPTION: Run Python CI steps (venv, install, test) on Windows.
# USAGE: ps\scripts\ci_python.ps1 [-Workdir <path>] [-SkipTest] [-Quick]
# PARAMETERS:
#   -Workdir <path>      Working directory (default: current dir).
#   -SkipTest            Skip pytest step.
#   -Quick               Skip install, only run tests.
#   -PythonBin <bin>     Python binary to use (auto-detected by default).
#   -TestCmd <tok...>    Override test command tokens (default: pytest).
#   -UseDocker           Run inside Docker Desktop instead of natively.
#   -Image <img>         Docker image override (requires -UseDocker).
#   -Help                Show this help message.
# EXAMPLE: .\ci_python.ps1 -TestCmd "pytest","-k","my test"
# ----------------------------------------------------
param(
    [string]   $Workdir   = '.',
    [switch]   $SkipTest,
    [switch]   $Quick,
    [string]   $PythonBin = '',
    [string[]] $TestCmd   = @('pytest'),
    [switch]   $UseDocker,
    [string]   $Image     = '',
    [switch]   $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging python docker ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }
if ($TestCmd.Count -eq 0) { Write-Error "-TestCmd must contain at least one token (the executable)."; exit 1 }

$absWorkdir = if ([System.IO.Path]::IsPathRooted($Workdir)) { $Workdir } else { Join-Path $PWD.Path $Workdir }
if (-not (Test-Path $absWorkdir -PathType Container)) { Write-Error "Working directory not found: $absWorkdir"; exit 1 }

if ($UseDocker) {
    if (-not (check_docker)) { exit 1 }
    $img     = if ($Image) { $Image } elseif ($env:CI_PYTHON_IMAGE) { $env:CI_PYTHON_IMAGE } else { 'python:3-slim' }
    $volArgs = @('run', '--rm', '-v', "${absWorkdir}:/work", '-w', '/work', $img)
    if (-not $Quick) {
        $req = Join-Path $absWorkdir 'requirements.txt'
        if (Test-Path $req) {
            log_info "pip install -r requirements.txt"
            docker @volArgs pip install -r requirements.txt
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }
    if (-not $SkipTest) {
        log_info "$($TestCmd -join ' ')"
        docker @volArgs @TestCmd
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} else {
    $py = python_resolve_3 $PythonBin
    if (-not $py) { Write-Error "Python 3.8+ not found on PATH."; exit 1 }
    log_info "Using Python: $py"

    $venv = Join-Path $absWorkdir '.venv'
    $venvPy = python_ensure_venv $py $venv
    activate_venv $venv

    if (-not $Quick) {
        $req = Join-Path $absWorkdir 'requirements.txt'
        if (Test-Path $req) {
            log_info "Installing dependencies from requirements.txt"
            & $venvPy -m pip install -r $req --quiet
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }
    if (-not $SkipTest) {
        log_info "Running: $($TestCmd -join ' ')"
        Push-Location $absWorkdir
        try {
            $exe     = $TestCmd[0]
            $cmdArgs = if ($TestCmd.Length -gt 1) { $TestCmd[1..($TestCmd.Length - 1)] } else { @() }
            & $exe @cmdArgs
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally { Pop-Location }
    }
}
print_success "Python CI complete."

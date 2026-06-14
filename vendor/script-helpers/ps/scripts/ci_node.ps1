# SCRIPT: ci_node.ps1
# DESCRIPTION: Run Node.js CI steps (install, lint, test, build) on Windows.
# USAGE: ps\scripts\ci_node.ps1 [-Workdir <path>] [-NoInstall] [-SkipLint] [-SkipTest] [-SkipBuild]
# PARAMETERS:
#   -Workdir <path>          Working directory for npm commands (default: current dir).
#   -NoInstall               Skip npm install step.
#   -SkipLint                Skip lint command.
#   -SkipTest                Skip test command.
#   -SkipBuild               Skip build command.
#   -InstallCmd <tok...>     Override install command tokens (default: npm ci).
#   -LintCmd <tok...>        Override lint command tokens (default: npm run lint).
#   -TestCmd <tok...>        Override test command tokens (default: npm run test).
#   -BuildCmd <tok...>       Override build command tokens (default: npm run build).
#   -UseDocker               Run inside Docker Desktop instead of natively.
#   -Image <img>             Docker image override (requires -UseDocker).
#   -Help                    Show this help message.
# EXAMPLE: .\ci_node.ps1 -TestCmd "npx","jest","--runInBand"
# ----------------------------------------------------
param(
    [string]   $Workdir    = '.',
    [switch]   $NoInstall,
    [switch]   $SkipLint,
    [switch]   $SkipTest,
    [switch]   $SkipBuild,
    [string[]] $InstallCmd = @('npm', 'ci'),
    [string[]] $LintCmd    = @('npm', 'run', 'lint'),
    [string[]] $TestCmd    = @('npm', 'run', 'test'),
    [string[]] $BuildCmd   = @('npm', 'run', 'build'),
    [switch]   $UseDocker,
    [string]   $Image      = '',
    [switch]   $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging docker ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = Resolve-Path $Workdir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path
if (-not $absWorkdir) { $absWorkdir = Join-Path $PWD.Path $Workdir }
if (-not (Test-Path $absWorkdir -PathType Container)) { Write-Error "Working directory not found: $absWorkdir"; exit 1 }
if ($UseDocker -and -not (check_docker)) { exit 1 }

function _Run {
    param([string[]]$Cmd)
    if (-not $Cmd -or $Cmd.Count -eq 0) { Write-Error "_Run: command array must not be empty"; exit 1 }
    $exe     = $Cmd[0]
    $cmdArgs = if ($Cmd.Length -gt 1) { $Cmd[1..($Cmd.Length - 1)] } else { @() }
    if ($UseDocker) {
        $img = if ($Image) { $Image } elseif ($env:CI_NODE_IMAGE) { $env:CI_NODE_IMAGE } else { 'node:22-alpine' }
        docker run --rm -v "${absWorkdir}:/work" -w /work $img $exe @cmdArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        Push-Location $absWorkdir
        try {
            & $exe @cmdArgs
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally { Pop-Location }
    }
}

log_info "Node CI — workdir: $absWorkdir"
if (-not $NoInstall) { log_info "Install: $($InstallCmd -join ' ')";  _Run $InstallCmd }
if (-not $SkipLint)  { log_info "Lint:    $($LintCmd -join ' ')";     _Run $LintCmd    }
if (-not $SkipTest)  { log_info "Test:    $($TestCmd -join ' ')";      _Run $TestCmd    }
if (-not $SkipBuild) { log_info "Build:   $($BuildCmd -join ' ')";    _Run $BuildCmd   }
print_success "Node CI complete."

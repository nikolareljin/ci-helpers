<#
.SYNOPSIS
  Native PowerShell entry for scripts/setup-hooks.sh: finds Git Bash and runs it with the same arguments.

.DESCRIPTION
  The hooks are bash scripts, and Claude Code runs them through Git Bash on
  Windows, so the setup lives in setup-hooks.sh only. This finds Git Bash
  (CLAUDE_CODE_GIT_BASH_PATH, then next to git.exe, then the standard install
  folders) and hands over. Without Git Bash it stops with exit 2 and says what
  to install.

.EXAMPLE
  git config --global script-helpers.owners <user-or-org>
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-hooks.ps1 --all
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-hooks.ps1 --doctor
#>
$ErrorActionPreference = 'Stop'

function Find-GitBash {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $candidates.Add($env:CLAUDE_CODE_GIT_BASH_PATH) }
    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        # git.exe is in <root>\cmd, <root>\bin or <root>\mingw64\bin.
        $dir = Split-Path -Parent $git.Source
        foreach ($up in @($dir, (Split-Path -Parent $dir), (Split-Path -Parent (Split-Path -Parent $dir)))) {
            if ($up) { $candidates.Add((Join-Path $up 'bin\bash.exe')) }
        }
        # <root>/mingw64/libexec/git-core
        $exec = & $git.Source --exec-path 2>$null
        if ($LASTEXITCODE -eq 0 -and $exec) {
            $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent ($exec -replace '/', '\')))
            if ($root) { $candidates.Add((Join-Path $root 'bin\bash.exe')) }
        }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) {
            $candidates.Add((Join-Path $base 'Git\bin\bash.exe'))
            $candidates.Add((Join-Path $base 'Programs\Git\bin\bash.exe'))
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

$onWindows = ($env:OS -eq 'Windows_NT')
$script = Join-Path $PSScriptRoot 'setup-hooks.sh'
if ($onWindows) {
    $bash = Find-GitBash
    if (-not $bash) {
        Write-Host '[setup-hooks] ERROR: Git Bash was not found. The hooks run under it.' -ForegroundColor Red
        Write-Host '[setup-hooks] Install Git for Windows (https://git-scm.com/download/win), open a new PowerShell, and run this again.'
        Write-Host '[setup-hooks] Installed somewhere else? Set CLAUDE_CODE_GIT_BASH_PATH to its bin\bash.exe.'
        exit 2
    }
    $script = $script -replace '\\', '/'
} else {
    $bash = 'bash'
}
& $bash $script @args
exit $LASTEXITCODE

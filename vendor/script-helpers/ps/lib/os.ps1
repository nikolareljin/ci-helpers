# OS detection helpers — PowerShell companion to lib/os.sh.

function get_os {
    # PS 6+ exposes $IsWindows / $IsLinux / $IsMacOS automatically.
    # PS 5.1 is Windows-only, so fall back to OSVersion.
    if (Get-Variable IsWindows -Scope Global -ErrorAction SilentlyContinue) {
        if ($IsWindows) { return 'windows' }
        if ($IsLinux)   { return 'linux'   }
        if ($IsMacOS)   { return 'mac'     }
    }
    $plat = [System.Environment]::OSVersion.Platform
    switch ($plat) {
        'Win32NT'  { return 'windows' }
        'Unix'     { return 'linux'   }
        default    { return 'unknown' }
    }
}

# Alias matching Bash module
function getos { get_os }

function is_wsl {
    if ($env:WSL_DISTRO_NAME) { return $true }
    $proc = '/proc/version'
    if (Test-Path $proc) {
        return (Get-Content $proc -ErrorAction SilentlyContinue) -match 'microsoft'
    }
    return $false
}

# On Windows there is no sudo; elevation is handled by UAC.
# This function is a no-op shim so scripts that call run_with_optional_sudo still work.
function run_with_optional_sudo {
    param([string]$UseSudo, [Parameter(ValueFromRemainingArguments)][string[]]$Cmd)
    if (-not $Cmd -or $Cmd.Length -eq 0) { throw "run_with_optional_sudo: no command provided" }
    $rest = if ($Cmd.Length -gt 1) { $Cmd[1..($Cmd.Length - 1)] } else { @() }
    & $Cmd[0] @rest
}

function is_admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [Security.Principal.WindowsPrincipal] $id
    return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# OS detection helpers - PowerShell companion to lib/os.sh.

# Usage: get_os
# Returns: 'windows', 'linux', 'mac' or 'unknown'.
# Output: none.
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
# Usage: getos
# Alias of get_os, matching the Bash module.
# Returns: as get_os.
# Output: none.
function getos { get_os }

# Usage: is_wsl
# Returns: $true under WSL (WSL_DISTRO_NAME set or /proc/version names microsoft), else $false.
# Output: none.
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
# Usage: run_with_optional_sudo <use_sudo> <command> [args...]
# Runs the command as is; use_sudo is ignored (Windows has no sudo; elevation is UAC).
# Returns: the command's own output; $LASTEXITCODE is the command's exit code.
# Output: whatever the command prints; throws when no command is given.
function run_with_optional_sudo {
    param([string]$UseSudo, [Parameter(ValueFromRemainingArguments)][string[]]$Cmd)
    if (-not $Cmd -or $Cmd.Length -eq 0) { throw "run_with_optional_sudo: no command provided" }
    $rest = if ($Cmd.Length -gt 1) { $Cmd[1..($Cmd.Length - 1)] } else { @() }
    & $Cmd[0] @rest
}

# Usage: is_admin
# Returns: $true when the session runs elevated as Administrator, else $false.
# Output: none. Windows only; throws elsewhere (no WindowsIdentity).
function is_admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [Security.Principal.WindowsPrincipal] $id
    return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

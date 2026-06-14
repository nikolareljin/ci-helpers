# Environment helpers — PowerShell companion to lib/env.sh.

function get_project_root {
    param([string]$StartDir = $PWD.Path)
    $dir = $StartDir
    while ($dir -ne [System.IO.Path]::GetPathRoot($dir)) {
        if (Test-Path (Join-Path $dir '.git')) { return $dir }
        $dir = Split-Path $dir -Parent
    }
    # Check the filesystem root itself (loop exits before evaluating it).
    if (Test-Path (Join-Path $dir '.git')) { return $dir }
    return $StartDir
}

function load_env {
    param([string]$EnvFile = '.env')
    if (-not (Test-Path $EnvFile)) {
        Write-Warning "[script-helpers] env file not found: $EnvFile"
        return
    }
    foreach ($_ in (Get-Content $EnvFile)) {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { continue }
        if ($line -match '^export\s+') { $line = $line -replace '^export\s+', '' }
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim() -replace '^"(.*)"$','$1' -replace "^'(.*)'$",'$1'
            $val = expand_env_refs $val
            [System.Environment]::SetEnvironmentVariable($key, $val, 'Process')
        }
    }
}

function require_env {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Names)
    $missing = @()
    foreach ($name in $Names) {
        if (-not [System.Environment]::GetEnvironmentVariable($name)) {
            $missing += $name
        }
    }
    if ($missing.Count -gt 0) {
        throw "[script-helpers] Required env vars not set: $($missing -join ', ')"
    }
}

# Mirror Bash resolve_env_value(key, default='', env_file='.env'):
# Returns the process env var value when set; falls back to reading $EnvFile
# for the key when the process env is unset/empty; finally returns $Default.
function resolve_env_value {
    param([string]$Name, [string]$Default = '', [string]$EnvFile = '.env')
    $v = [System.Environment]::GetEnvironmentVariable($Name)
    if ($null -ne $v -and $v -ne '') { return $v }
    if ($EnvFile -and (Test-Path $EnvFile)) {
        # Mirror load_env parsing: handle export prefix, spaces around =, quotes.
        $matched = $null
        foreach ($line in (Get-Content $EnvFile -ErrorAction SilentlyContinue)) {
            $l = $line.Trim()
            if ($l -match '^\s*#' -or $l -eq '') { continue }
            if ($l -match '^export\s+') { $l = $l -replace '^export\s+', '' }
            if ($l -match '^([^=]+)=(.*)$') {
                if ($Matches[1].Trim() -eq $Name) { $matched = $Matches[2] }
            }
        }
        if ($null -ne $matched) {
            $v = $matched.Trim() -replace '^"(.*)"$','$1' -replace "^'(.*)'$",'$1'
            $v = ($v -replace '\s*#.*$', '').Trim()
            if ($v -ne '') { return $v }
        }
    }
    return $Default
}

# Expand ${VAR} and $VAR references inside a value string using the current
# process environment. Used internally by load_env.
function expand_env_refs {
    param([string]$Value)
    $result = $Value
    # Unset vars expand to empty string, matching Bash load_env behaviour.
    $result = [regex]::Replace($result, '\$\{([^}]+)\}', {
        param($m)
        $v = [System.Environment]::GetEnvironmentVariable($m.Groups[1].Value)
        if ($null -ne $v) { $v } else { '' }
    })
    $result = [regex]::Replace($result, '\$([A-Za-z_][A-Za-z0-9_]*)', {
        param($m)
        $v = [System.Environment]::GetEnvironmentVariable($m.Groups[1].Value)
        if ($null -ne $v) { $v } else { '' }
    })
    return $result
}

# Loader for script-helpers PowerShell companion library.
# Dot-source this file, then call Import-ScriptHelpers with module names.
#
# Usage:
#   . "$env:SCRIPT_HELPERS_DIR\ps\helpers.ps1"
#   Import-ScriptHelpers logging env docker
#
# Or from a script file, with auto-detection:
#   . (Join-Path $PSScriptRoot '..\script-helpers\ps\helpers.ps1')
#   Import-ScriptHelpers logging

function _Shlib_ResolveRoot {
    if ($env:SCRIPT_HELPERS_DIR -and (Test-Path $env:SCRIPT_HELPERS_DIR)) {
        return $env:SCRIPT_HELPERS_DIR
    }
    # Resolve relative to this file: ps/helpers.ps1 -> repo root is one level up
    return Split-Path -Parent $PSScriptRoot
}

$_SHLIB_ROOT_DIR = _Shlib_ResolveRoot
$_SHLIB_LIB_DIR  = Join-Path $_SHLIB_ROOT_DIR 'ps\lib'

# Track the script that dot-sourced helpers.ps1.
# $MyInvocation.ScriptName is reliable when dot-sourced from a .ps1 file but can be
# empty when invoked from the console or certain host environments. Fall back to the
# call stack to find the first caller outside this file.
$_shlib_caller = $MyInvocation.ScriptName
if (-not $_shlib_caller) {
    $_shlib_caller = (Get-PSCallStack |
        Where-Object { $_.ScriptName -and $_.ScriptName -ne $PSCommandPath } |
        Select-Object -First 1).ScriptName
}
if ($_shlib_caller) { $env:SHLIB_CALLER_SCRIPT = $_shlib_caller }

$env:SCRIPT_HELPERS_DIR = $_SHLIB_ROOT_DIR

# Tracks which modules have already been loaded to avoid re-sourcing.
$_SHLIB_LOADED = @{}

# Import-ScriptHelpers: load one or more modules by name.
# Logging is always loaded first (auto-imported if not explicitly requested).
function Import-ScriptHelpers {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Modules)

    # Always ensure logging is loaded first so other modules can use it during import.
    _Shlib_SourceModule 'logging'
    foreach ($name in @($Modules)) {
        _Shlib_SourceModule $name
    }
}

function _Shlib_SourceModule {
    param([string]$Name)
    if ($_SHLIB_LOADED.ContainsKey($Name)) { return }
    if ($Name -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') {
        throw "[script-helpers] Invalid module name: $Name"
    }
    $file = Join-Path $_SHLIB_LIB_DIR "$Name.ps1"
    if (-not (Test-Path $file)) {
        throw "[script-helpers] Unknown module: $Name"
    }
    # Dot-sourcing inside a function puts symbols in the function's transient scope.
    # New-Module + Import-Module -Global exports them into the global session state.
    $sb = [scriptblock]::Create([System.IO.File]::ReadAllText($file))
    New-Module -Name "shlib_$Name" -ScriptBlock $sb | Import-Module -Global -Force
    $_SHLIB_LOADED[$Name] = $true
}

# Import-ScriptHelpersAll: load every available module.
# Logging is always loaded first (same invariant as Import-ScriptHelpers).
function Import-ScriptHelpersAll {
    _Shlib_SourceModule 'logging'
    Get-ChildItem -Path $_SHLIB_LIB_DIR -Filter '*.ps1' | ForEach-Object {
        _Shlib_SourceModule $_.BaseName
    }
}

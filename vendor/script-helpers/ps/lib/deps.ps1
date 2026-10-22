# Dependency helpers - PowerShell companion to lib/deps.sh.
# Uses winget (Windows 11 built-in) > choco > scoop for package installation.

function _Deps_GetPackageManager {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }
    if (Get-Command choco  -ErrorAction SilentlyContinue) { return 'choco'  }
    if (Get-Command scoop  -ErrorAction SilentlyContinue) { return 'scoop'  }
    return $null
}

# Usage: install_package <package> [<package>...]
# Installs each package with winget, else choco, else scoop.
# Returns: nothing. A failed package is warned about and the rest still run.
# Output: the package manager's output; stderr [WARN] when no manager is found or an install fails.
function install_package {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Packages)
    $mgr = _Deps_GetPackageManager
    if (-not $mgr) {
        if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn "No package manager found (winget/choco/scoop). Install packages manually: $($Packages -join ', ')" }
        else { Write-Warning "No package manager found. Install manually: $($Packages -join ', ')" }
        return
    }
    foreach ($pkg in $Packages) {
        switch ($mgr) {
            'winget' { winget install $pkg --accept-package-agreements --accept-source-agreements }
            'choco'  { choco install $pkg -y }
            'scoop'  { scoop install $pkg }
        }
        if ($LASTEXITCODE -ne 0) {
            $msg = "Failed to install package '$pkg' via $mgr (exit $LASTEXITCODE)"
            if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn $msg }
            else { Write-Warning $msg }
        }
    }
}

# Usage: install_dependencies [-Packages <string[]>]   (default: curl, jq, git, wget)
# Returns: nothing (see install_package).
# Output: as install_package.
function install_dependencies {
    param([string[]]$Packages = @('curl', 'jq', 'git', 'wget'))
    install_package @Packages
}

# Usage: require_command <name> [<name>...]
# Returns: nothing when every command resolves.
# Output: stderr [ERROR] listing the missing commands; then throws the same message.
function require_command {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Names)
    $missing = @()
    foreach ($name in $Names) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        $msg = "Required commands not found: $($missing -join ', ')"
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error $msg }
        throw $msg
    }
}

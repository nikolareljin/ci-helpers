# Dependency helpers — PowerShell companion to lib/deps.sh.
# Uses winget (Windows 11 built-in) > choco > scoop for package installation.

function _Deps_GetPackageManager {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }
    if (Get-Command choco  -ErrorAction SilentlyContinue) { return 'choco'  }
    if (Get-Command scoop  -ErrorAction SilentlyContinue) { return 'scoop'  }
    return $null
}

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

function install_dependencies {
    param([string[]]$Packages = @('curl', 'jq', 'git', 'wget'))
    install_package @Packages
}

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

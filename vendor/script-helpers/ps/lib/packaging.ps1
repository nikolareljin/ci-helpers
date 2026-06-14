# Packaging metadata helpers — PowerShell companion to lib/packaging.sh.
# Linux-specific formats (deb/rpm/arch) are not applicable on Windows.
#
# pkg_* functions mirror the Bash public API (pipe-delimited list strings).
# PS-idiomatic helpers (join_by, quote_args) are also retained.

function join_by {
    param([string]$Separator, [string[]]$Items)
    return ($Items -join $Separator)
}

function quote_args {
    param([string[]]$Items)
    return ($Items | ForEach-Object { '"' + $_ + '"' })
}

function load_packaging_metadata {
    param([string]$MetaFile = 'packaging.json')
    if (-not (Test-Path $MetaFile)) {
        if (Test-Path 'package.json') { $MetaFile = 'package.json' }
        else { throw "No packaging metadata file found (packaging.json / package.json)" }
    }
    return (Get-Content $MetaFile -Raw | ConvertFrom-Json)
}

function get_package_version {
    param([string]$MetaFile = '')
    if ($MetaFile) {
        $meta = load_packaging_metadata $MetaFile
        return $meta.version
    }
    if (Test-Path 'VERSION') { return (Get-Content 'VERSION' -Raw).Trim() }
    $meta = load_packaging_metadata
    return $meta.version
}

function to_camel_case {
    param([string]$Value)
    $parts = ($Value -split '[_\-\s]+') | Where-Object { $_ }
    return ($parts | ForEach-Object {
        if ($_.Length -eq 1) { $_.ToUpper() }
        else { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }
    }) -join ''
}

# --- Bash API-compatible pkg_* functions ---

function pkg_load_metadata {
    param([string]$File = 'packaging/packaging.env')
    if (-not (Test-Path $File)) { throw "Packaging metadata not found: $File" }
    foreach ($_ in (Get-Content $File)) {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { continue }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim() -replace '^"(.*)"$','$1' -replace "^'(.*)'$",'$1'
            [System.Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }
}

function pkg_require_vars {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Names)
    $missing = @()
    foreach ($n in $Names) {
        if (-not [System.Environment]::GetEnvironmentVariable($n)) { $missing += $n }
    }
    if ($missing.Count -gt 0) { throw "Missing required packaging vars: $($missing -join ', ')" }
}

function pkg_trim { param([string]$Value); return $Value.Trim() }

function pkg_join_list {
    param([string]$List, [string]$Separator)
    $items = ($List -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return ($items -join $Separator)
}

function pkg_quote_list {
    param([string]$List)
    return (($List -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ' '
}

function pkg_render_lines {
    param([string]$Prefix, [string]$List)
    ($List -split '\|') | ForEach-Object {
        $item = $_.Trim()
        if ($item) { Write-Output "$Prefix$item" }
    }
}

function pkg_classify_name {
    param([string]$Name)
    return to_camel_case $Name
}

function pkg_guess_version {
    param([string]$RepoDir = '.')
    $vf = Join-Path $RepoDir 'VERSION'
    if (Test-Path $vf) { return (Get-Content $vf -Raw).Trim() }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $tag = git -C $RepoDir describe --tags --abbrev=0 2>$null
        if ($LASTEXITCODE -eq 0 -and $tag) { return $tag.Trim() }
    }
    return '0.1.0'
}

# Packaging metadata helpers - PowerShell companion to lib/packaging.sh.
# Linux-specific formats (deb/rpm/arch) are not applicable on Windows.
#
# pkg_* functions mirror the Bash public API (pipe-delimited list strings).
# PS-idiomatic helpers (join_by, quote_args) are also retained.

# Usage: join_by -Separator <s> -Items <string[]>
# Returns: the items joined by Separator.
# Output: none.
function join_by {
    param([string]$Separator, [string[]]$Items)
    return ($Items -join $Separator)
}

# Usage: quote_args -Items <string[]>
# Returns: each item wrapped in double quotes.
# Output: none.
function quote_args {
    param([string[]]$Items)
    return ($Items | ForEach-Object { '"' + $_ + '"' })
}

# Usage: load_packaging_metadata [-MetaFile <path>]   (default: packaging.json, else package.json)
# Returns: the parsed JSON object.
# Output: none; throws when no metadata file exists or the JSON is invalid.
function load_packaging_metadata {
    param([string]$MetaFile = 'packaging.json')
    if (-not (Test-Path $MetaFile)) {
        if (Test-Path 'package.json') { $MetaFile = 'package.json' }
        else { throw "No packaging metadata file found (packaging.json / package.json)" }
    }
    return (Get-Content $MetaFile -Raw | ConvertFrom-Json)
}

# Usage: get_package_version [-MetaFile <path>]
# Returns: .version of MetaFile; without one, VERSION's content, else .version of the metadata file.
# Output: none; throws as load_packaging_metadata.
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

# Usage: to_camel_case -Value <string>
# Returns: Value split on _, - and spaces, each part capitalized and joined (my-app -> MyApp).
# Output: none.
function to_camel_case {
    param([string]$Value)
    $parts = ($Value -split '[_\-\s]+') | Where-Object { $_ }
    return ($parts | ForEach-Object {
        if ($_.Length -eq 1) { $_.ToUpper() }
        else { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }
    }) -join ''
}

# --- Bash API-compatible pkg_* functions ---

# Usage: pkg_load_metadata [-File <path>]   (default: packaging/packaging.env)
# Sets process environment variables from KEY=VALUE lines (quotes stripped).
# Returns: nothing.
# Output: none; throws when the file is missing.
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

# Usage: pkg_require_vars <NAME> [<NAME>...]
# Returns: nothing when every variable is set.
# Output: none; throws "Missing required packaging vars: <names>" otherwise.
function pkg_require_vars {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Names)
    $missing = @()
    foreach ($n in $Names) {
        if (-not [System.Environment]::GetEnvironmentVariable($n)) { $missing += $n }
    }
    if ($missing.Count -gt 0) { throw "Missing required packaging vars: $($missing -join ', ')" }
}

# Usage: pkg_trim -Value <string>
# Returns: Value without leading and trailing whitespace.
# Output: none.
function pkg_trim { param([string]$Value); return $Value.Trim() }

# Usage: pkg_join_list -List <a|b|c> -Separator <s>
# Returns: the non-empty, trimmed items joined by Separator.
# Output: none.
function pkg_join_list {
    param([string]$List, [string]$Separator)
    $items = ($List -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return ($items -join $Separator)
}

# Usage: pkg_quote_list -List <a|b|c>
# Returns: the non-empty items single-quoted and space-separated.
# Output: none.
function pkg_quote_list {
    param([string]$List)
    return (($List -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ' '
}

# Usage: pkg_render_lines -Prefix <p> -List <a|b|c>
# Returns: one "<Prefix><item>" line per non-empty item.
# Output: none.
function pkg_render_lines {
    param([string]$Prefix, [string]$List)
    ($List -split '\|') | ForEach-Object {
        $item = $_.Trim()
        if ($item) { Write-Output "$Prefix$item" }
    }
}

# Usage: pkg_classify_name -Name <name>
# Returns: to_camel_case of Name.
# Output: none.
function pkg_classify_name {
    param([string]$Name)
    return to_camel_case $Name
}

# Usage: pkg_guess_version [-RepoDir <dir>]
# Returns: VERSION's content, else the latest git tag, else '0.1.0'.
# Output: none.
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

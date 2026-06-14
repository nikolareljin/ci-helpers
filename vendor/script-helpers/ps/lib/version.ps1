# Semantic version helpers — PowerShell companion to lib/version.sh.

function _Version_Parse {
    param([string]$Raw)
    $raw = $Raw -replace '^[vV]','' -replace '-.*$',''
    if ($raw -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid version format: $raw (expected X.Y.Z)"
    }
    $parts = $raw -split '\.'
    return @{ Major = [int]$parts[0]; Minor = [int]$parts[1]; Patch = [int]$parts[2] }
}

# Returns 0 (equal), 1 (a > b), -1 (a < b).
function version_compare {
    param([string]$VersionA, [string]$VersionB)
    $a = _Version_Parse $VersionA
    $b = _Version_Parse $VersionB
    if ($a.Major -ne $b.Major) { return [math]::Sign($a.Major - $b.Major) }
    if ($a.Minor -ne $b.Minor) { return [math]::Sign($a.Minor - $b.Minor) }
    return [math]::Sign($a.Patch - $b.Patch)
}

function version_bump {
    param(
        [ValidateSet('major','minor','patch')][string]$BumpType,
        [string]$VersionFile = 'VERSION'
    )
    if (-not $BumpType) { throw "version_bump: BumpType is required (major/minor/patch)" }
    if (-not [System.IO.Path]::IsPathRooted($VersionFile)) {
        $root = if (Get-Command get_project_root -ErrorAction SilentlyContinue) { get_project_root } else { $PWD.Path }
        $VersionFile = Join-Path $root $VersionFile
    }

    $current  = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '0.1.0' }
    $original = $current   # preserve for success message before mutations strip prefix/suffix

    $prefix = ''
    if ($current -match '^([vV])(.+)$') { $prefix = $Matches[1]; $current = $Matches[2] }
    $suffix = ''
    if ($current -match '^([^-]+)(-.+)$') { $suffix = $Matches[2]; $current = $Matches[1] }

    $v = _Version_Parse $current
    switch ($BumpType) {
        'major' { $v.Major++; $v.Minor = 0; $v.Patch = 0 }
        'minor' { $v.Minor++; $v.Patch = 0 }
        'patch' { $v.Patch++ }
    }

    $newCore    = "$($v.Major).$($v.Minor).$($v.Patch)"
    $newVersion = "$prefix$newCore$suffix"
    $parentDir  = Split-Path $VersionFile -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    Set-Content -Path $VersionFile -Value $newVersion -Encoding ascii

    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Bumped version: $original -> $newVersion" }
    else { Write-Host "Bumped version: $original -> $newVersion" }
    return $newVersion
}

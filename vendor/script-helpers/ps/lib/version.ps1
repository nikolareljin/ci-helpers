# Semantic version helpers - PowerShell companion to lib/version.sh.

function _Version_Parse {
    param([string]$Raw)
    $raw = $Raw -replace '^[vV]','' -replace '-.*$',''
    if ($raw -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid version format: $raw (expected X.Y.Z)"
    }
    $parts = $raw -split '\.'
    return @{ Major = [int]$parts[0]; Minor = [int]$parts[1]; Patch = [int]$parts[2] }
}

# Usage: version_compare -VersionA <x.y.z> -VersionB <x.y.z>
# A leading v and a -suffix are ignored.
# Returns: 1 when A > B, 0 when equal, -1 when A < B.
# Output: none; throws "Invalid version format" when either is not X.Y.Z.
function version_compare {
    param([string]$VersionA, [string]$VersionB)
    $a = _Version_Parse $VersionA
    $b = _Version_Parse $VersionB
    if ($a.Major -ne $b.Major) { return [math]::Sign($a.Major - $b.Major) }
    if ($a.Minor -ne $b.Minor) { return [math]::Sign($a.Minor - $b.Minor) }
    return [math]::Sign($a.Patch - $b.Patch)
}

# Usage: version_project_root
# The caller's project root: the top of the git work tree holding the cwd, or
# the cwd outside git. When that work tree is a script-helpers checkout vendored
# as a submodule, the superproject is the project.
# Returns: the absolute directory as a string.
# Output: nothing else; git errors are discarded.
function version_project_root {
    $top = ''
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $top = "$(& git rev-parse --show-toplevel 2>$null)".Trim()
            if ($LASTEXITCODE -ne 0) { $top = '' }
            if ($top -and (Test-Path (Join-Path $top 'helpers.sh')) -and (Test-Path (Join-Path $top 'lib'))) {
                $super = "$(& git -C $top rev-parse --show-superproject-working-tree 2>$null)".Trim()
                if ($LASTEXITCODE -eq 0 -and $super) { $top = $super }
            }
        } finally { $ErrorActionPreference = $prev }
    }
    if (-not $top) { return $PWD.Path }
    return [System.IO.Path]::GetFullPath($top)
}

# Usage: version_bump -BumpType major|minor|patch [-VersionFile <path>]
# Without -VersionFile: VERSION at version_project_root (the project's, never a
# vendored script-helpers copy's). A relative -VersionFile is relative to the cwd.
# Bumps the version in the file (0.1.0 when missing), keeping a v prefix and -suffix.
# Returns: the new version string.
# Output: host "Bumped version: <old> -> <new>"; throws on a missing BumpType or a bad version.
function version_bump {
    param(
        [ValidateSet('major','minor','patch')][string]$BumpType,
        [string]$VersionFile = ''
    )
    if (-not $BumpType) { throw "version_bump: BumpType is required (major/minor/patch)" }
    if (-not $VersionFile) {
        $VersionFile = Join-Path (version_project_root) 'VERSION'
    } elseif (-not [System.IO.Path]::IsPathRooted($VersionFile)) {
        $VersionFile = Join-Path $PWD.Path $VersionFile
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

    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Bumped version: $original -> $newVersion" | Out-Host }
    else { Write-Host "Bumped version: $original -> $newVersion" }
    return $newVersion
}

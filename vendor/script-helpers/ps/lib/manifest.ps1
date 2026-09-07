# Version manifests — PowerShell companion to lib/manifest.sh.
#
# A phone app routinely states its version in three places at once: pubspec.yaml
# for Flutter, versionName/versionCode in a Gradle build file for the Play Store,
# and a VERSION file for a companion host component. They drift, and a release
# ships with two different numbers in it.
#
#   pubspec       pubspec.yaml            version: 1.2.3+45
#   gradle        build.gradle[.kts]      versionName "1.2.3" / versionCode 10203
#   version_file  VERSION                 1.2.3
#   package_json  package.json            "version": "1.2.3"
#   pyproject     pyproject.toml          version = "1.2.3"

# The manifest kind for a path, based on its name. $null when unrecognized.
function manifest_kind {
    param([Parameter(Mandatory)][string]$File)
    switch ([System.IO.Path]::GetFileName($File)) {
        'pubspec.yaml'      { return 'pubspec' }
        'build.gradle'      { return 'gradle' }
        'build.gradle.kts'  { return 'gradle' }
        'VERSION'           { return 'version_file' }
        'package.json'      { return 'package_json' }
        'pyproject.toml'    { return 'pyproject' }
        default {
            if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "manifest_kind: unrecognized manifest '$File'" }
            return $null
        }
    }
}

# One object per version manifest found, with Kind and Path. Searches the
# directory and two levels down — an app under mobile/ or android/ is the
# common layout.
function manifest_detect {
    param([string]$Dir = '.')
    $names = @('pubspec.yaml','build.gradle','build.gradle.kts','VERSION','package.json','pyproject.toml')
    $pruned = '[\\/](node_modules|build|\.dart_tool|vendor|\.git|\.gradle|target)[\\/]'
    Get-ChildItem -Path $Dir -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
        Where-Object { $names -contains $_.Name -and $_.FullName -notmatch $pruned } |
        Sort-Object FullName |
        ForEach-Object {
            $kind = manifest_kind $_.FullName
            if ($kind) { [PSCustomObject]@{ Kind = $kind; Path = $_.FullName } }
        }
}

# The version recorded in a manifest. For a pubspec the build number after `+`
# is dropped — that is a build counter, not part of the version.
function manifest_read_version {
    param([Parameter(Mandatory)][string]$File)
    if (-not (Test-Path $File -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "manifest_read_version: not found: $File" }
        return $null
    }
    $kind = manifest_kind $File
    if (-not $kind) { return $null }
    $text = Get-Content $File -Raw
    $version = $null
    switch ($kind) {
        'pubspec'      { if ($text -match '(?m)^version:\s*([0-9][^\s+]*)') { $version = $Matches[1] } }
        'gradle'       { if ($text -match 'versionName\s*[=(]*\s*"([^"]+)"')  { $version = $Matches[1] } }
        'version_file' { $version = ($text -split "`n")[0].Trim() }
        'package_json' { if ($text -match '"version"\s*:\s*"([^"]+)"')        { $version = $Matches[1] } }
        'pyproject'    { if ($text -match '(?m)^version\s*=\s*"([^"]+)"')     { $version = $Matches[1] } }
    }
    if (-not $version) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "manifest_read_version: no version found in $File" }
        return $null
    }
    return $version
}

# The integer Play Store versionCode for a semver string, as
# MAJOR*10000 + MINOR*100 + PATCH plus an optional offset.
#
# The Play Store requires a strictly increasing integer, and this mapping stays
# monotonic while minor and patch remain below 100. Returns $null on non-semver
# rather than a wrong number, which the Play Store rejects only after upload.
function manifest_android_version_code {
    param([Parameter(Mandatory)][string]$Version, [int]$Offset = 0)
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)') {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "manifest_android_version_code: not a semver version: '$Version'" }
        return $null
    }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
    if (($minor -ge 100 -or $patch -ge 100) -and (Get-Command log_warn -ErrorAction SilentlyContinue)) {
        log_warn "manifest_android_version_code: minor/patch >= 100 in $Version — the code is no longer monotonic"
    }
    return ($major * 10000 + $minor * 100 + $patch + $Offset)
}

# Set the version in a manifest, in place. For gradle, versionCode is recomputed
# unless -Build overrides it; for a pubspec, -Build sets the `+n` suffix and an
# existing suffix is preserved when it is not given.
function manifest_write_version {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Version,
        [string]$Build
    )
    if (-not (Test-Path $File -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "manifest_write_version: not found: $File" }
        return $false
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+') {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "manifest_write_version: not a semver version: '$Version'" }
        return $false
    }
    $kind = manifest_kind $File
    if (-not $kind) { return $false }
    $text = Get-Content $File -Raw

    switch ($kind) {
        'pubspec' {
            if (-not $Build -and $text -match '(?m)^version:\s*[0-9][^\s+]*\+(\d+)') { $Build = $Matches[1] }
            $new = if ($Build) { "version: $Version+$Build" } else { "version: $Version" }
            $text = $text -replace '(?m)^version:.*', $new
        }
        'gradle' {
            $code = if ($Build) { $Build } else { manifest_android_version_code $Version }
            if (-not $code) { return $false }
            $text = $text -replace '(versionName\s*[=(]*\s*)"[^"]*"', "`${1}`"$Version`""
            $text = $text -replace '(versionCode\s*[=(]*\s*)\d+',     "`${1}$code"
        }
        'version_file' { $text = "$Version`n" }
        'package_json' { $text = $text -replace '("version"\s*:\s*)"[^"]*"', "`${1}`"$Version`"" }
        'pyproject'    { $text = $text -replace '(?m)^(version\s*=\s*)"[^"]*"', "`${1}`"$Version`"" }
    }

    if (-not $text) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) {
            log_error "manifest_write_version: rewriting $File produced an empty file — refusing to replace it"
        }
        return $false
    }
    Set-Content -Path $File -Value $text -NoNewline
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "manifest: $File -> $Version" }
    return $true
}

# Write $Version into every manifest under $Dir. The "one release, one number"
# operation. Attempts all of them and reports a partial sync rather than hiding it.
function manifest_sync_version {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Version,
        [string]$Build
    )
    $ok = $true
    foreach ($m in (manifest_detect $Dir)) {
        $written = if ($Build) {
            manifest_write_version -File $m.Path -Version $Version -Build $Build
        } else {
            manifest_write_version -File $m.Path -Version $Version
        }
        if (-not $written) { $ok = $false }
    }
    if (-not $ok -and (Get-Command log_error -ErrorAction SilentlyContinue)) {
        log_error 'manifest_sync_version: one or more manifests were not updated'
    }
    return $ok
}

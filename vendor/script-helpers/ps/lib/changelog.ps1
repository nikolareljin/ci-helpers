# CHANGELOG maintenance — PowerShell companion to lib/changelog.sh.
#
# The header format is load-bearing, not a style preference: ci-helpers extracts
# GitHub Release notes from CHANGELOG.md by finding the section for the tag being
# released. Any other header shape and the notes silently fall back to an
# auto-generated commit list. The canonical form is
#
#     ## 2026-07-28 — v0.19.0
#
# YYYY-MM-DD, space, em-dash, space, version with an optional `v` prefix.

# Both dash styles are matched so the checker can tell "wrong dash" from "wrong
# shape entirely" and say which.
$script:ChangelogHeaderRe = '^##\s+(\d{4}-\d{2}-\d{2})\s+(—|-{1,2})\s+v?(\d+\.\d+\.\d+\S*)\s*$'

# Verify the newest release header conforms. Returns the version on success and
# $null on failure, with an explanation. An `## [Unreleased]` section at the top
# is allowed and skipped over.
function changelog_check_header {
    param([Parameter(Mandatory)][string]$File)
    if (-not (Test-Path $File -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "changelog_check_header: not found: $File" }
        return $null
    }
    $first = $null
    foreach ($line in (Get-Content $File)) {
        if ($line -notmatch '^##\s') { continue }
        if ($line -match '^##\s+\[?[Uu]nreleased\]?') { continue }
        $first = $line
        break
    }
    if (-not $first) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "changelog_check_header: $File has no release section at all" }
        return $null
    }
    if ($first -match $script:ChangelogHeaderRe) {
        if ($Matches[2] -ne '—') {
            if (Get-Command log_error -ErrorAction SilentlyContinue) {
                log_error "changelog_check_header: $File uses an ASCII hyphen where the format needs an em-dash:"
                log_error "  $first"
                log_error "Expected: ## $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')) — v$($Matches[3])"
            }
            return $null
        }
        return $Matches[3]
    }
    if (Get-Command log_error -ErrorAction SilentlyContinue) {
        log_error "changelog_check_header: $File's newest release header does not conform:"
        log_error "  $first"
        log_error 'Expected: ## YYYY-MM-DD — vX.Y.Z  (ci-helpers extracts release notes from this)'
    }
    return $null
}

# The body of the section for $Version, without its header, for use as release
# notes. The `v` prefix is optional on both sides.
function changelog_extract {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Version
    )
    if (-not (Test-Path $File -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "changelog_extract: not found: $File" }
        return $null
    }
    $bare = $Version -replace '^v',''
    $inside = $false
    $body = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content $File)) {
        if ($line -match '^##\s') {
            if ($inside) { break }
            if ($line.Contains($bare)) { $inside = $true }
            continue
        }
        if ($inside) { $body.Add($line) }
    }
    if (-not $inside) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "changelog_extract: no section for $Version in $File" }
        return $null
    }
    return (($body -join "`n").Trim())
}

# Insert a new release section at the top, above the newest existing one and
# below any `## [Unreleased]` placeholder. Refuses to run twice for the same
# version, so it is safe in a release script that gets rerun.
function changelog_new_section {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Version,
        [string]$Date,
        [string[]]$Sections = @('Added','Changed','Fixed','Security')
    )
    if ($Version -notmatch '^v?\d+\.\d+\.\d+') {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "changelog_new_section: not a semver version: '$Version'" }
        return $false
    }
    if (-not $Date) { $Date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }
    $bare = $Version -replace '^v',''

    if (-not (Test-Path $File)) {
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "changelog: creating $File" }
        Set-Content -Path $File -Value "# Changelog`n"
    }

    $lines = @(Get-Content $File)
    $escaped = [regex]::Escape($bare)
    if ($lines | Where-Object { $_ -match "^##\s.*$escaped(\D|$)" }) {
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "changelog: $File already has a section for $bare" }
        return $true
    }

    $block = New-Object System.Collections.Generic.List[string]
    $block.Add("## $Date — v$bare")
    $block.Add('')
    foreach ($s in $Sections) { $block.Add("### $s"); $block.Add('') }

    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in $lines) {
        if (-not $inserted -and $line -match '^##\s' -and $line -notmatch '^##\s+\[?[Uu]nreleased\]?') {
            $block | ForEach-Object { $out.Add($_) }
            $inserted = $true
        }
        $out.Add($line)
    }
    # No existing release section: append after the title block.
    if (-not $inserted) { $block | ForEach-Object { $out.Add($_) } }

    Set-Content -Path $File -Value ($out -join "`n")
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "changelog: added section $Date — v$bare to $File" }
    return $true
}

# File and directory helpers — PowerShell companion to lib/file.sh.

function command_exists {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function file_exists     { param([string]$Path); return (Test-Path $Path -PathType Leaf) }
function directory_exists { param([string]$Path); return (Test-Path $Path -PathType Container) }

function create_directory {
    param([string]$Path)
    if (Test-Path $Path -PathType Container) {
        Write-Host "Directory $Path already exists."
        return $true
    }
    try {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        Write-Host "Directory $Path created."
        return $true
    } catch {
        Write-Error "create_directory: failed to create '$Path': $_"
        return $false
    }
}

function download_file {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Output = ''
    )
    try {
        if (-not $Output) {
            $Output = [System.IO.Path]::GetFileName(([uri]$Url).LocalPath)
        }
        Write-Host "[script-helpers] Downloading $Url -> $Output"
        $iwrArgs = @{ Uri = $Url; OutFile = $Output; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -lt 6) { $iwrArgs['UseBasicParsing'] = $true }
        # Suppress the response object and the noisy PS progress bar; callers get $true/$false only.
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest @iwrArgs | Out-Null } finally { $ProgressPreference = $prev }
        return $true
    } catch {
        Write-Error "download_file: failed to download '$Url': $_"
        return $false
    }
}

function verify_checksum {
    param(
        [string]$FilePath,
        [string]$ExpectedHash,
        [string]$Algorithm = 'SHA256'
    )
    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Error "verify_checksum: file not found: $FilePath"
        return $false
    }
    try {
        $actual = (Get-FileHash -Path $FilePath -Algorithm $Algorithm -ErrorAction Stop).Hash
    } catch {
        Write-Error "verify_checksum: could not hash '$FilePath': $_"
        return $false
    }
    if ($actual -eq $ExpectedHash.Trim().ToUpper()) {
        if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Checksum OK: $FilePath" }
        else { Write-Host "Checksum OK: $FilePath" }
        return $true
    } else {
        if (Get-Command print_error -ErrorAction SilentlyContinue) { print_error "Checksum MISMATCH for $FilePath" }
        else { Write-Error "Checksum MISMATCH for $FilePath" }
        return $false
    }
}

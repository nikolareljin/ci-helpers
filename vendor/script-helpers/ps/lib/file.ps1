# File and directory helpers - PowerShell companion to lib/file.sh.

# Usage: command_exists -Name <command>
# Returns: $true when the command resolves (cmdlet, function, alias or executable), else $false.
# Output: none.
function command_exists {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

# Usage: file_exists -Path <path>
# Returns: $true when Path is a file, else $false.
# Output: none.
function file_exists     { param([string]$Path); return (Test-Path $Path -PathType Leaf) }
# Usage: directory_exists -Path <path>
# Returns: $true when Path is a directory, else $false.
# Output: none.
function directory_exists { param([string]$Path); return (Test-Path $Path -PathType Container) }

# Usage: create_directory -Path <path>
# Returns: $true when the directory exists or was created, $false when creation failed.
# Output: host "Directory <path> created." or "... already exists."; error stream on failure.
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

# Usage: download_file -Url <url> [-Output <path>]   (default: the URL's file name)
# Returns: $true on success, $false on failure.
# Output: host the "Downloading" line; error stream on failure.
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

# Usage: verify_checksum -FilePath <path> -ExpectedHash <hex> [-Algorithm SHA256]
# Returns: $true when the hash matches (case-insensitive), else $false.
# Output: host "Checksum OK" or "[Error!]: Checksum MISMATCH"; error stream when the file
#   is missing or cannot be hashed.
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
        if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Checksum OK: $FilePath" | Out-Host }
        else { Write-Host "Checksum OK: $FilePath" }
        return $true
    } else {
        if (Get-Command print_error -ErrorAction SilentlyContinue) { print_error "Checksum MISMATCH for $FilePath" | Out-Host }
        else { Write-Error "Checksum MISMATCH for $FilePath" }
        return $false
    }
}

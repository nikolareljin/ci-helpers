# Ollama installation on Windows -- PowerShell companion to lib/ollama_install.sh.
#
# Installs Ollama from a source that can be checked: winget (Ollama.Ollama; winget
# checks the installer against its manifest), else the official release zip of
# the version pinned in ci_defaults, compared with the pinned SHA-256 before it
# is unpacked. No setup program is run for the zip, and nothing needs elevation:
# it goes under the user's own LocalAppData.
#
# On Linux and macOS use the Bash module (lib/ollama_install.sh).
#
# Function names mirror the Bash module so the docs are shared.
#
# Requires: logging, ci_defaults
#
# Return codes (as the Bash module): 0 installed or already there at the pinned
# version or newer; 1 the download failed or does not match the pinned SHA-256;
# 3 the platform has no checkable source.

if (-not $env:CI_DEFAULT_OLLAMA_VERSION) {
    . (Join-Path $PSScriptRoot 'ci_defaults.ps1')
}

# ollama_install_asset: the release zip for this machine, or $null.
function ollama_install_asset {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:_SHLIB_OLLAMA_ARCH) { $arch = $env:_SHLIB_OLLAMA_ARCH }  # test seam
    switch -Regex ($arch) {
        '^(AMD64|x86_64)$' { return 'ollama-windows-amd64.zip' }
        '^(ARM64|aarch64)$' { return 'ollama-windows-arm64.zip' }
        default { return $null }
    }
}

# ollama_install_expected_sha256 <asset>: the pinned SHA-256, or $null.
function ollama_install_expected_sha256([string]$Asset) {
    switch ($Asset) {
        'ollama-windows-amd64.zip' { return $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 }
        'ollama-windows-arm64.zip' { return $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64 }
        default { return $null }
    }
}

# ollama_installed_version: the version of the ollama on PATH, or $null.
# `ollama --version` reports a running server's version first; the binary's own
# is the "client version" line. It is asked with OLLAMA_HOST at a port nothing
# listens on, and a "client version" line wins.
function ollama_installed_version([string]$Binary = 'ollama') {
    if (-not (Get-Command $Binary -ErrorAction SilentlyContinue)) { return $null }
    $saved = $env:OLLAMA_HOST
    try {
        $env:OLLAMA_HOST = '127.0.0.1:9'
        $out = (& $Binary --version 2>&1 | Out-String)
    } finally { $env:OLLAMA_HOST = $saved }
    if ($out -match 'client version is (\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($out -match '(\d+)\.(\d+)\.(\d+)') { return $Matches[0] }
    return $null
}

# _ollama_install_at_least <have> <want>: $true when have >= want.
function _ollama_install_at_least([string]$Have, [string]$Want) {
    try { return ([version]$Have) -ge ([version]$Want) } catch { return $false }
}

# ollama_install [-Prefix <dir>] [-Force]
# Returns 0, 1 or 3 as above (as a value, and as $LASTEXITCODE is not touched).
function ollama_install {
    param([string]$Prefix = '', [switch]$Force)
    $version = $env:CI_DEFAULT_OLLAMA_VERSION
    $base = if ($env:OLLAMA_RELEASE_BASE_URL) { $env:OLLAMA_RELEASE_BASE_URL } else { 'https://github.com/ollama/ollama/releases/download' }

    $have = ollama_installed_version
    if ($have -and -not $Force -and (_ollama_install_at_least $have $version)) {
        log_info "Ollama $have is installed (pinned: $version); nothing to do."
        return 0
    }

    if (-not $Prefix -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        # An older Ollama is upgraded: `winget install` stops at one that is there.
        # When winget has nothing newer, the pinned zip goes to the same place
        # Ollama's own installer uses.
        $verb = if ($have) { 'upgrade' } else { 'install' }
        log_info "Ollama with winget ($verb)."
        & winget $verb --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            $now = ollama_installed_version
            if ($now -and -not (_ollama_install_at_least $now $version)) {
                log_warn "Ollama $now is installed; the pinned version is $version. winget has nothing newer yet."
            } else {
                log_info 'Ollama installed. It starts with Windows; or run: ollama serve.'
            }
            return 0
        }
        log_warn "winget $verb did not succeed (exit $LASTEXITCODE); using the release zip."
    }

    $asset = ollama_install_asset
    if (-not $asset) {
        log_error "ollama_install: no checkable Ollama archive for $($env:PROCESSOR_ARCHITECTURE). See https://ollama.com/download."
        return 3
    }
    $want = ollama_install_expected_sha256 $asset
    if (-not ($want -match '^[0-9a-f]{64}$')) {
        log_error "ollama_install: no pinned SHA-256 for $asset (CI_DEFAULT_OLLAMA_SHA256_*)"
        return 3
    }
    if (-not $Prefix) {
        $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }
        $Prefix = Join-Path (Join-Path $local 'Programs') 'Ollama'
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ollama-install-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $asset
        $url = "$($base.TrimEnd('/'))/v$version/$asset"
        log_info "Downloading Ollama $version ($asset)."
        try {
            $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        } catch {
            log_error "ollama_install: download failed: $url"
            return 1
        } finally { $ProgressPreference = $prev }
        $got = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $want) {
            log_error "ollama_install: $asset $version does not match the pinned SHA-256 (got $got, want $want); nothing was installed."
            return 1
        }
        # Unpack into a staging directory first: a damaged zip fails before
        # anything installed is touched.
        $stage = Join-Path $tmp 'stage'
        try {
            Expand-Archive -Path $zip -DestinationPath $stage -Force -ErrorAction Stop
        } catch {
            log_error "ollama_install: unpacking $asset failed: $($_.Exception.Message)"
            return 1
        }
        if (-not (Test-Path (Join-Path $stage 'ollama.exe'))) {
            log_error "ollama_install: $asset has no ollama.exe"
            return 1
        }
        try {
            New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
            # An upgrade must not leave the old version's libraries beside the
            # new ones. Only that directory is removed.
            $oldLib = Join-Path (Join-Path $Prefix 'lib') 'ollama'
            if (Test-Path $oldLib) { Remove-Item -Recurse -Force $oldLib -ErrorAction Stop }
            Copy-Item -Path (Join-Path $stage '*') -Destination $Prefix -Recurse -Force -ErrorAction Stop
        } catch {
            # A running ollama.exe is locked: stop Ollama, then install again.
            log_error "ollama_install: installing into $Prefix failed: $($_.Exception.Message)"
            return 1
        }
        log_info "Ollama $version installed in $Prefix. Add it to PATH, then run: ollama serve."
        return 0
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

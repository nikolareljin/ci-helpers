# Flutter project helpers — PowerShell companion to lib/flutter.sh.
#
# flutter_resolve_sdk exists because Flutter is routinely installed somewhere a
# non-interactive shell's PATH does not reach. This is that lookup, once.

function _Flutter_IsWindows { return ($IsWindows -or $env:OS -eq 'Windows_NT') }

function _Flutter_ExeName {
    if (_Flutter_IsWindows) { return 'flutter.bat' }
    return 'flutter'
}

# Path to a usable flutter executable, or $null. Honours FLUTTER_ROOT and
# FLUTTER_HOME. Does not modify PATH — the caller decides.
function flutter_resolve_sdk {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = _Flutter_ExeName
    $candidates = @(
        (Join-Path $env:FLUTTER_ROOT "bin\$exe"),
        (Join-Path $env:FLUTTER_ROOT "bin/$exe"),
        (Join-Path $env:FLUTTER_HOME "bin/$exe"),
        (Join-Path $HOME "flutter/bin/$exe"),
        (Join-Path $HOME "development/flutter/bin/$exe"),
        (Join-Path $HOME ".local/flutter/bin/$exe"),
        (Join-Path $HOME "fvm/default/bin/$exe"),
        "C:\src\flutter\bin\$exe",
        "/opt/flutter/bin/$exe",
        "/usr/local/flutter/bin/$exe",
        "/snap/bin/$exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -PathType Leaf)) { return $c }
    }
    return $null
}

function flutter_available { return [bool](flutter_resolve_sdk) }

# Every other function goes through here, so SDK resolution and the "not
# installed" message live in exactly one place.
# $CmdArgs, not $Args: `Args` is an automatic variable in PowerShell and using it
# as a parameter name shadows it. adb.ps1 uses $Cmd for the same reason.
function flutter_run_cmd {
    param(
        [string]$Dir,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$CmdArgs
    )
    if (-not $Dir -or -not $CmdArgs -or $CmdArgs.Count -eq 0) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'flutter_run_cmd: need <dir> <arg...>' }
        return $false
    }
    $bin = flutter_resolve_sdk
    if (-not $bin) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) {
            log_error 'flutter_run_cmd: flutter not found. Install it, or set FLUTTER_ROOT.'
        }
        return $false
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "flutter: $($CmdArgs -join ' ') (in $Dir)" }
    Push-Location $Dir
    try {
        & $bin @CmdArgs
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function flutter_pub_get  { param([string]$Dir = '.') flutter_run_cmd $Dir 'pub' 'get' }
function flutter_analyze  { param([string]$Dir = '.') flutter_run_cmd $Dir 'analyze' }

# Fails when any Dart file is unformatted. --set-exit-if-changed is what makes
# this a check rather than a rewrite.
function flutter_format_check {
    param([string]$Dir = '.')
    $bin = flutter_resolve_sdk
    if (-not $bin) { return $false }
    # `(if ...)` is not an expression in PowerShell; assign first.
    $dartName = 'dart'
    if (_Flutter_IsWindows) { $dartName = 'dart.bat' }
    $dart = Join-Path (Split-Path $bin -Parent) $dartName
    if (-not (Test-Path $dart)) { $dart = 'dart' }
    Push-Location $Dir
    try {
        & $dart format --output=none --set-exit-if-changed .
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function flutter_test {
    param([string]$Dir = '.', [switch]$Coverage)
    if ($Coverage) { return flutter_run_cmd $Dir 'test' '--coverage' }
    return flutter_run_cmd $Dir 'test'
}

# Build an artifact. Defaults to release, because a Flutter build with no mode
# flag is a debug build and that is rarely what a caller of a build function means.
function flutter_build {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('apk','appbundle','ios','web','linux','macos','windows')][string]$Target,
        [string]$Dir = '.',
        [ValidateSet('release','debug','profile')][string]$Mode = 'release',
        [string]$Flavor
    )
    $buildArgs = @('build', $Target, "--$Mode")
    if ($Flavor) { $buildArgs += @('--flavor', $Flavor) }
    return flutter_run_cmd $Dir @buildArgs
}

# One object per connected device, with Id and Name.
function flutter_devices {
    param([string]$Dir = '.')
    $bin = flutter_resolve_sdk
    if (-not $bin) { return }
    Push-Location $Dir
    try {
        $json = & $bin devices --machine 2>$null | Out-String
        if ($json.Trim()) {
            try {
                foreach ($d in ($json | ConvertFrom-Json)) {
                    [PSCustomObject]@{ Id = $d.id; Name = $d.name }
                }
                return
            } catch {
                # Fall through to the table parser below.
            }
        }
        foreach ($line in (& $bin devices 2>$null)) {
            $parts = $line -split '\s+•\s+'
            if ($parts.Count -ge 3) {
                $name = ($parts[0] -replace '\s*\([^()]*\)\s*$','').Trim()
                [PSCustomObject]@{ Id = $parts[1].Trim(); Name = $name }
            }
        }
    } finally {
        Pop-Location
    }
}

# The device id to build against: $Preferred if connected, else FLUTTER_DEVICE,
# else the only connected device. $null when the choice is ambiguous — an
# ambiguous device is a question for the caller, not a guess.
function flutter_resolve_device {
    param([string]$Preferred = $env:FLUTTER_DEVICE, [string]$Dir = '.')
    $devices = @(flutter_devices $Dir)
    if ($Preferred) {
        if ($devices.Id -contains $Preferred) { return $Preferred }
        if (Get-Command log_error -ErrorAction SilentlyContinue) {
            log_error "flutter_resolve_device: '$Preferred' is not connected"
        }
        return $null
    }
    if ($devices.Count -eq 1) { return $devices[0].Id }
    if ($devices.Count -eq 0) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'flutter_resolve_device: no devices connected' }
        return $null
    }
    if (Get-Command log_error -ErrorAction SilentlyContinue) {
        log_error "flutter_resolve_device: $($devices.Count) devices connected — pass one explicitly:"
    }
    $devices | ForEach-Object { Write-Error "  $($_.Id)`t$($_.Name)" }
    return $null
}

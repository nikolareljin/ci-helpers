# Screen capture — PowerShell companion to lib/screencap.sh.
#
# Screenshots and screen video off a phone, tablet, emulator or simulator, for
# README media, store listings and bug reports.
#
#   android   adb exec-out screencap   /  adb shell screenrecord + adb pull
#   ios       xcrun simctl io screenshot / recordVideo   (macOS only)
#
# Two device limits are reported rather than hidden: `screenrecord` caps a clip
# at 180 seconds and records no audio, so longer requests are chunked and
# concatenated; and a physical iOS device cannot be recorded without Xcode
# driving it, which fails with an explanation instead of appearing to succeed.
#
# On Windows only the Android backend is available, because simctl is macOS-only.
#
# Import: Import-ScriptHelpers logging adb screencap

$script:ScreencapAndroidMaxSeconds = 180

function _Screencap_HasIos {
    if (-not $IsMacOS) { return $false }
    return [bool](Get-Command xcrun -ErrorAction SilentlyContinue)
}

function screencap_available {
    if ((Get-Command adb_available -ErrorAction SilentlyContinue) -and (adb_available)) {
        if (@(adb_ready_serials).Count -gt 0) { return $true }
    }
    if ((Get-Command ios_booted_simulators -ErrorAction SilentlyContinue) -and (_Screencap_HasIos)) {
        if (@(ios_booted_simulators).Count -gt 0) { return $true }
    }
    return $false
}

# Fill in whichever of platform/device the caller left blank. Refuses to guess
# when more than one device is present. Returns @{Platform=..; Device=..} or $null.
function _Screencap_Resolve {
    param([string]$Platform, [string]$Device)

    if ($Device -and -not $Platform) {
        # A simulator UDID is long hyphenated hex; an adb serial is not.
        if ($Device -match '^[0-9A-Fa-f-]{30,}$') { $Platform = 'ios' } else { $Platform = 'android' }
    }

    $serials = @()
    $sims    = @()
    if (Get-Command adb_ready_serials -ErrorAction SilentlyContinue) { $serials = @(adb_ready_serials) }
    if ((Get-Command ios_booted_simulators -ErrorAction SilentlyContinue) -and (_Screencap_HasIos)) {
        $sims = @(ios_booted_simulators)
    }

    if (-not $Platform) {
        if ($serials.Count -gt 0 -and $sims.Count -eq 0)      { $Platform = 'android' }
        elseif ($sims.Count -gt 0 -and $serials.Count -eq 0)  { $Platform = 'ios' }
        elseif ($serials.Count -eq 0 -and $sims.Count -eq 0)  {
            if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap: no ready Android device and no booted iOS simulator' }
            return $null
        } else {
            if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap: both Android and iOS targets are present — pass -Platform' }
            return $null
        }
    }

    if (-not $Device) {
        switch ($Platform) {
            'android' {
                if ($serials.Count -eq 0) {
                    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap: no ready Android device' }
                    return $null
                }
                if ($serials.Count -gt 1) {
                    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "screencap: $($serials.Count) Android devices ready — pass -Device" }
                    $serials | ForEach-Object { Write-Error "  $_" }
                    return $null
                }
                $Device = $serials[0]
            }
            'ios' {
                if ($sims.Count -eq 0) {
                    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap: no booted iOS simulator' }
                    return $null
                }
                if ($sims.Count -gt 1) {
                    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "screencap: $($sims.Count) simulators booted — pass -Device" }
                    $sims | ForEach-Object { Write-Error "  $_" }
                    return $null
                }
                $Device = $sims[0]
            }
            default {
                if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "screencap: platform must be android or ios, got '$Platform'" }
                return $null
            }
        }
    }
    return @{ Platform = $Platform; Device = $Device }
}

# The conventional output path, creating the directory. Media lands where a
# README can reference it.
function _Screencap_DefaultOut {
    param([string]$Device, [string]$Extension)
    $dir = if ($env:SCREENCAP_DIR) { $env:SCREENCAP_DIR } else { 'docs/screenshots' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $safe  = ($Device -replace '[^A-Za-z0-9_.-]','_')
    return (Join-Path $dir "$stamp-$safe.$Extension")
}

# Capture a single PNG. With no arguments, targets the only connected device and
# writes to docs/screenshots/. Returns the path written.
function screencap_shot {
    param([string]$Device, [string]$Platform, [string]$Out)

    $r = _Screencap_Resolve $Platform $Device
    if (-not $r) { return $null }
    if (-not $Out) { $Out = _Screencap_DefaultOut $r.Device 'png' }
    $parent = Split-Path $Out -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    if ($r.Platform -eq 'android') {
        # exec-out keeps the PNG binary-clean; `adb shell screencap -p` mangles
        # newlines on some devices. cmd /c is the reliable way to get a raw
        # binary redirect out of adb on Windows PowerShell.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'adb'
        $psi.Arguments = "-s $($r.Device) exec-out screencap -p"
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $fs = [System.IO.File]::Create($Out)
        try {
            $proc.StandardOutput.BaseStream.CopyTo($fs)
        } finally {
            $fs.Close()
            $proc.WaitForExit()
        }
    } else {
        & xcrun simctl io $r.Device screenshot $Out 2>$null | Out-Null
    }

    if (-not (Test-Path $Out) -or (Get-Item $Out).Length -eq 0) {
        Remove-Item $Out -Force -ErrorAction SilentlyContinue
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "screencap_shot: capture failed on $($r.Device)" }
        return $null
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "screencap: wrote $Out" }
    return $Out
}

# Capture screen video. Android clips longer than 180 seconds are recorded in
# chunks and concatenated, which needs ffmpeg; without ffmpeg a longer request is
# refused rather than silently truncated. Returns the path written.
function screencap_record {
    param(
        [string]$Device,
        [string]$Platform,
        [string]$Out,
        [int]$Seconds = 30,
        [string]$Size,
        [string]$Bitrate,
        [switch]$Gif
    )
    if ($Seconds -le 0) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap_record: -Seconds must be positive' }
        return $null
    }
    $r = _Screencap_Resolve $Platform $Device
    if (-not $r) { return $null }
    if (-not $Out) { $Out = _Screencap_DefaultOut $r.Device 'mp4' }
    $parent = Split-Path $Out -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $ok = if ($r.Platform -eq 'android') {
        _Screencap_RecordAndroid $r.Device $Out $Seconds $Size $Bitrate
    } else {
        _Screencap_RecordIos $r.Device $Out $Seconds
    }
    if (-not $ok) { return $null }

    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "screencap: wrote $Out" }
    if ($Gif) {
        $gifPath = [System.IO.Path]::ChangeExtension($Out, 'gif')
        if (-not (screencap_gif $Out $gifPath)) {
            if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn 'screencap_record: video written, GIF conversion failed' }
        }
    }
    return $Out
}

function _Screencap_RecordAndroid {
    param([string]$Serial, [string]$Out, [int]$Seconds, [string]$Size, [string]$Bitrate)
    $remote = "/sdcard/screencap-$PID.mp4"
    $flags = @()
    if ($Size)    { $flags += @('--size', $Size) }
    if ($Bitrate) { $flags += @('--bit-rate', $Bitrate) }

    if ($Seconds -le $script:ScreencapAndroidMaxSeconds) {
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "screencap: recording ${Seconds}s on $Serial" }
        & adb -s $Serial shell screenrecord --time-limit $Seconds @flags $remote
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { & adb -s $Serial pull $remote $Out 2>$null | Out-Null; $rc = $LASTEXITCODE }
        & adb -s $Serial shell rm -f $remote 2>$null | Out-Null
        if ($rc -ne 0 -and (Get-Command log_error -ErrorAction SilentlyContinue)) {
            log_error "_Screencap_RecordAndroid: recording failed on $Serial"
        }
        return ($rc -eq 0)
    }

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) {
            log_error "screencap_record: ${Seconds}s exceeds screenrecord's $($script:ScreencapAndroidMaxSeconds)s cap and ffmpeg is not installed to join chunks."
            log_error "Install ffmpeg, or ask for $($script:ScreencapAndroidMaxSeconds)s or less."
        }
        return $false
    }

    $tmpdir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpdir -Force | Out-Null
    $list = Join-Path $tmpdir 'chunks.txt'
    if (Get-Command log_info -ErrorAction SilentlyContinue) {
        log_info "screencap: recording ${Seconds}s on $Serial in $($script:ScreencapAndroidMaxSeconds)s chunks"
    }
    $left = $Seconds; $index = 0; $ok = $true
    while ($left -gt 0) {
        $chunk = [Math]::Min($left, $script:ScreencapAndroidMaxSeconds)
        & adb -s $Serial shell screenrecord --time-limit $chunk @flags $remote
        if ($LASTEXITCODE -ne 0) { $ok = $false; break }
        $part = Join-Path $tmpdir "part-$index.mp4"
        & adb -s $Serial pull $remote $part 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $ok = $false; break }
        Add-Content -Path $list -Value ("file '" + ($part -replace '\\','/') + "'")
        & adb -s $Serial shell rm -f $remote 2>$null | Out-Null
        $left -= $chunk
        $index++
    }
    if ($ok) {
        & ffmpeg -y -f concat -safe 0 -i $list -c copy $Out 2>$null | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    Remove-Item $tmpdir -Recurse -Force -ErrorAction SilentlyContinue
    & adb -s $Serial shell rm -f $remote 2>$null | Out-Null
    return $ok
}

function _Screencap_RecordIos {
    param([string]$Udid, [string]$Out, [int]$Seconds)
    if (Get-Command ios_booted_simulators -ErrorAction SilentlyContinue) {
        if (@(ios_booted_simulators) -notcontains $Udid) {
            if (Get-Command log_error -ErrorAction SilentlyContinue) {
                log_error "screencap_record: '$Udid' is not a booted simulator."
                log_error 'Recording a physical iOS device needs Xcode or QuickTime driving it; simctl cannot do it.'
            }
            return $false
        }
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "screencap: recording ${Seconds}s on simulator $Udid" }
    # recordVideo runs until interrupted; stopping the process is what finalizes it.
    $proc = Start-Process -FilePath 'xcrun' `
        -ArgumentList @('simctl','io',$Udid,'recordVideo','--codec','h264','--force',$Out) `
        -NoNewWindow -PassThru
    Start-Sleep -Seconds $Seconds
    if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 2 }
    if (-not $proc.HasExited) { $proc.Kill() }
    return ((Test-Path $Out) -and (Get-Item $Out).Length -gt 0)
}

# Extract a still frame from a recording, for a README image taken from a demo
# clip. Defaults to 1 second in, because frame zero is often blank.
function screencap_frame {
    param(
        [Parameter(Mandatory)][string]$Video,
        [Parameter(Mandatory)][string]$Out,
        [double]$At = 1
    )
    if (-not (Test-Path $Video -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "screencap_frame: not found: $Video" }
        return $null
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap_frame: ffmpeg is not installed' }
        return $null
    }
    $parent = Split-Path $Out -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    & ffmpeg -y -ss $At -i $Video -frames:v 1 $Out 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap_frame: extraction failed' }
        return $null
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "screencap: wrote $Out" }
    return $Out
}

# Convert a recording to a GIF suitable for a README. Two-pass with a generated
# palette, because a single-pass GIF from video is visibly dithered.
function screencap_gif {
    param(
        [Parameter(Mandatory)][string]$Video,
        [Parameter(Mandatory)][string]$Out,
        [int]$Fps = 12,
        [int]$Width = 480
    )
    if (-not (Test-Path $Video -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "screencap_gif: not found: $Video" }
        return $null
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap_gif: ffmpeg is not installed' }
        return $null
    }
    $parent = Split-Path $Out -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $palette = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.png')
    try {
        & ffmpeg -y -i $Video -vf "fps=$Fps,scale=${Width}:-1:flags=lanczos,palettegen" $palette 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'palettegen failed' }
        & ffmpeg -y -i $Video -i $palette -lavfi "fps=$Fps,scale=${Width}:-1:flags=lanczos[x];[x][1:v]paletteuse" $Out 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'paletteuse failed' }
    } catch {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'screencap_gif: conversion failed' }
        return $null
    } finally {
        Remove-Item $palette -Force -ErrorAction SilentlyContinue
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "screencap: wrote $Out" }
    return $Out
}

# Stop an in-flight recording started outside screencap_record's own timed wait.
# Safe to call when nothing is recording.
function screencap_record_stop {
    param([string]$Device)
    if ($Device) {
        & adb -s $Device shell pkill -INT screenrecord 2>$null | Out-Null
    } elseif (Get-Command adb_ready_serials -ErrorAction SilentlyContinue) {
        foreach ($s in @(adb_ready_serials)) {
            & adb -s $s shell pkill -INT screenrecord 2>$null | Out-Null
        }
    }
    Get-Process -Name 'simctl' -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
    return $true
}

# adb / Android device helpers — PowerShell companion to lib/adb.sh.
#
# A general toolkit for inspecting and debugging Android devices over USB via the
# Android Debug Bridge (adb). Multi-device safe: always targets a device with
# `adb -s <serial>` rather than a bare `adb shell` (which errors with "more than
# one device" once a second device is attached). Function names mirror the Bash
# module so docs/usage are shared.

# --- discovery -------------------------------------------------------------

function adb_available {
    return [bool](Get-Command adb -ErrorAction SilentlyContinue)
}

function adb_ready_serials {
    if (-not (adb_available)) { return }
    foreach ($line in (& adb devices 2>$null)) {
        $parts = $line -split '\s+'
        if ($parts.Count -ge 2 -and $parts[1] -eq 'device') { Write-Output $parts[0] }
    }
}

# --- device info -----------------------------------------------------------

function adb_getprop {
    param([string]$Serial, [string]$Prop)
    if (-not (adb_available) -or -not $Serial -or -not $Prop) { return }
    (& adb -s $Serial shell getprop $Prop 2>$null | Out-String).Trim()
}

function adb_device_model    { param([string]$Serial) adb_getprop $Serial 'ro.product.model' }
function adb_android_version { param([string]$Serial) adb_getprop $Serial 'ro.build.version.release' }
function adb_device_api      { param([string]$Serial) adb_getprop $Serial 'ro.build.version.sdk' }

function adb_device_ip {
    param([string]$Serial, [string]$Iface = 'wlan0')
    if (-not (adb_available) -or -not $Serial) { return }
    $out = (& adb -s $Serial shell ip -f inet addr show $Iface 2>$null | Out-String)
    if ($out -match 'inet (\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
}

# A table (objects) of every ready device with model, Android OS, API level, IP.
function adb_list_devices {
    param([string]$Iface = 'wlan0')
    if (-not (adb_available)) {
        if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn 'adb not found. Install the Android platform-tools and put adb on PATH.' }
        return
    }
    $serials = @(adb_ready_serials)
    if ($serials.Count -eq 0) {
        if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn "No ready devices. Check the USB cable and 'adb devices' (authorize the on-phone prompt)." }
        return
    }
    foreach ($s in $serials) {
        [PSCustomObject]@{
            SERIAL  = $s
            MODEL   = (adb_device_model $s)
            ANDROID = (adb_android_version $s)
            API     = (adb_device_api $s)
            IP      = (adb_device_ip $s $Iface)
        }
    }
}

# --- shell / debugging -----------------------------------------------------

function adb_shell {
    param(
        [string]$Serial,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Cmd
    )
    if (-not (adb_available) -or -not $Serial -or -not $Cmd -or $Cmd.Count -eq 0) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'adb_shell: need <serial> <command...>' }
        return
    }
    & adb -s $Serial shell @Cmd
}

function adb_logcat {
    param([string]$Serial, [string]$Regex)
    if (-not (adb_available) -or -not $Serial) { return }
    $out = & adb -s $Serial logcat -d 2>$null
    if ($Regex) { $out | Select-String -Pattern $Regex } else { $out }
}

function adb_clear_logcat {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return }
    & adb -s $Serial logcat -c 2>$null
}

# --- file transfer ---------------------------------------------------------

function adb_push {
    param([string]$Serial, [string]$LocalPath, [string]$RemotePath)
    if (-not (adb_available)) { return }
    if (-not $Serial -or -not $LocalPath -or -not $RemotePath) { log_error 'adb_push: need <serial> <local> <remote>'; return }
    if (-not (Test-Path $LocalPath)) { log_error "adb_push: local path not found: $LocalPath"; return }
    log_info "push $LocalPath -> ${Serial}:$RemotePath"
    & adb -s $Serial push $LocalPath $RemotePath
}

function adb_pull {
    param([string]$Serial, [string]$RemotePath, [string]$LocalPath = '.')
    if (-not (adb_available)) { return }
    if (-not $Serial -or -not $RemotePath) { log_error 'adb_pull: need <serial> <remote> [local]'; return }
    log_info "pull ${Serial}:$RemotePath -> $LocalPath"
    & adb -s $Serial pull $RemotePath $LocalPath
}

# --- apps ------------------------------------------------------------------

# -User defaults to 0, the device owner, and is passed through to adb. This is
# not a cosmetic default. An unqualified `adb install` can land the package in a
# profile the shell cannot subsequently read — on a device with a work profile or
# Samsung Secure Folder the install prints Success and exits 0 while
# `pm list packages` fails with "SecurityException: Shell does not have
# permission to access user <id>". The app is then absent from the launcher and
# unstartable, with every signal saying the install worked.
function adb_install {
    param(
        [string]$Serial, [string]$Apk,
        [int]$User = 0,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ExtraArgs
    )
    if (-not (adb_available)) { return }
    if (-not $Serial -or -not $Apk) { log_error 'adb_install: need <serial> <apk>'; return }
    if (-not (Test-Path $Apk)) { log_error "adb_install: APK not found: $Apk"; return }
    log_info "install $Apk -> $Serial (user $User)"
    & adb -s $Serial install -r --user $User @ExtraArgs $Apk
    return ($LASTEXITCODE -eq 0)
}

# True when the package is visible to that user. $null when the shell is not
# permitted to query the user at all — which is itself the answer, because a
# package the shell cannot see is a package the launcher will not show.
#
# Call this after adb_install. An installer's exit code asserts that adb accepted
# the command, not that the app is usable.
function adb_installed_for_user {
    param([string]$Serial, [string]$Package, [int]$User = 0)
    if (-not (adb_available)) { return $null }
    if (-not $Serial -or -not $Package) { log_error 'adb_installed_for_user: need <serial> <package> [user]'; return $null }
    $out = (& adb -s $Serial shell pm list packages --user $User 2>&1 | Out-String)
    if ($out -match 'SecurityException') {
        log_error "adb_installed_for_user: the shell cannot read user $User on $Serial."
        log_error 'A package installed there will not appear in the launcher. Available users:'
        & adb -s $Serial shell pm list users 2>$null | Write-Host
        return $null
    }
    return ($out -split "`r?`n" | Where-Object { $_.Trim() -eq "package:$Package" }).Count -gt 0
}

# Install, then confirm the package is actually visible to that user. This is
# what a deploy path should call: adb_install alone reports what adb accepted,
# not what the device will show.
function adb_install_verified {
    param(
        [string]$Serial, [string]$Apk, [string]$Package,
        [int]$User = 0,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ExtraArgs
    )
    if (-not $Serial -or -not $Apk -or -not $Package) {
        log_error 'adb_install_verified: need <serial> <apk> <package>'
        return $false
    }
    if (-not (adb_install -Serial $Serial -Apk $Apk -User $User @ExtraArgs)) { return $false }

    $seen = adb_installed_for_user -Serial $Serial -Package $Package -User $User
    if ($seen -eq $true) {
        log_info "verified: $Package is present for user $User on $Serial"
        return $true
    }
    log_error "adb_install_verified: '$Package' installed without error but is NOT visible to user $User."
    log_error 'This is what a work profile or Secure Folder install looks like: adb reports Success,'
    log_error "the launcher shows nothing, and 'am start' cannot find it."
    log_error 'Pick the right profile with -User <id>. Available users:'
    & adb -s $Serial shell pm list users 2>$null | Write-Host
    return $false
}

function adb_install_all {
    param(
        [string]$Apk,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ExtraArgs
    )
    if (-not (adb_available)) { return $false }
    if (-not $Apk -or -not (Test-Path $Apk)) { log_error "adb_install_all: APK not found: $Apk"; return $false }
    $serials = @(adb_ready_serials)
    if ($serials.Count -eq 0) { log_warn 'No ready devices to install to.'; return $true }
    $ok = 0; $fail = 0
    foreach ($s in $serials) {
        & adb -s $s install -r @ExtraArgs $Apk *> $null
        if ($LASTEXITCODE -eq 0) { log_info "installed on $s"; $ok++ } else { log_warn "install FAILED on $s"; $fail++ }
    }
    log_info "install summary: $ok ok, $fail failed of $($serials.Count) device(s)"
    # Mirror lib/adb.sh's non-zero-on-any-failure contract: $true iff all succeeded.
    return ($fail -eq 0)
}

function adb_uninstall {
    param([string]$Serial, [string]$Package)
    if (-not (adb_available)) { return }
    if (-not $Serial -or -not $Package) { log_error 'adb_uninstall: need <serial> <package>'; return }
    & adb -s $Serial uninstall $Package
}

# --- status ----------------------------------------------------------------

function adb_battery_level {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return }
    $out = (& adb -s $Serial shell dumpsys battery 2>$null | Out-String)
    if ($out -match '(?m)^\s*level:\s*(\d+)') { return $Matches[1] }
}

# Returns $true (on), $false (off), or $null (unknown).
function adb_screen_on {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return $null }
    $out = (& adb -s $Serial shell dumpsys power 2>$null | Out-String)
    if ($out -match 'Display Power: state=ON|mScreenOn=true|mWakefulness=Awake') { return $true }
    if ($out -match 'Display Power: state=OFF|mScreenOn=false|mWakefulness=(Asleep|Dozing)') { return $false }
    return $null
}

function adb_device_status {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return }
    $screen = adb_screen_on $Serial
    $screenText = if ($screen -eq $true) { 'on' } elseif ($screen -eq $false) { 'off' } else { 'unknown' }
    [PSCustomObject]@{
        serial  = $Serial
        model   = (adb_device_model $Serial)
        android = "$(adb_android_version $Serial) (API $(adb_device_api $Serial))"
        battery = "$(adb_battery_level $Serial)%"
        screen  = $screenText
        wifi_ip = (adb_device_ip $Serial)
    }
}

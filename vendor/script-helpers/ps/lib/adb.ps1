# adb / Android device helpers - PowerShell companion to lib/adb.sh.
#
# A general toolkit for inspecting and debugging Android devices over USB via the
# Android Debug Bridge (adb). Multi-device safe: always targets a device with
# `adb -s <serial>` rather than a bare `adb shell` (which errors with "more than
# one device" once a second device is attached). Function names mirror the Bash
# module so docs/usage are shared.

# --- discovery -------------------------------------------------------------

# Usage: adb_available
# Returns: $true when adb is on PATH, else $false.
# Output: none.
function adb_available {
    return [bool](Get-Command adb -ErrorAction SilentlyContinue)
}

# Usage: adb_ready_serials
# Returns: the serial of each device in state `device`; nothing without adb or devices.
# Output: none.
function adb_ready_serials {
    if (-not (adb_available)) { return }
    foreach ($line in (& adb devices 2>$null)) {
        $parts = $line -split '\s+'
        if ($parts.Count -ge 2 -and $parts[1] -eq 'device') { Write-Output $parts[0] }
    }
}

# --- device info -----------------------------------------------------------

# Usage: adb_getprop -Serial <serial> -Prop <property>
# Returns: the property value, trimmed; nothing without adb, serial or property.
# Output: none.
function adb_getprop {
    param([string]$Serial, [string]$Prop)
    if (-not (adb_available) -or -not $Serial -or -not $Prop) { return }
    (& adb -s $Serial shell getprop $Prop 2>$null | Out-String).Trim()
}

# Usage: adb_device_model -Serial <serial>
# Returns: ro.product.model (see adb_getprop).
# Output: none.
function adb_device_model    { param([string]$Serial) adb_getprop $Serial 'ro.product.model' }
# Usage: adb_android_version -Serial <serial>
# Returns: ro.build.version.release (see adb_getprop).
# Output: none.
function adb_android_version { param([string]$Serial) adb_getprop $Serial 'ro.build.version.release' }
# Usage: adb_device_api -Serial <serial>
# Returns: ro.build.version.sdk (see adb_getprop).
# Output: none.
function adb_device_api      { param([string]$Serial) adb_getprop $Serial 'ro.build.version.sdk' }

# Usage: adb_device_ip -Serial <serial> [-Iface <name>]   (default: wlan0)
# Returns: the interface's IPv4 address; nothing when it has none.
# Output: none.
function adb_device_ip {
    param([string]$Serial, [string]$Iface = 'wlan0')
    if (-not (adb_available) -or -not $Serial) { return }
    $out = (& adb -s $Serial shell ip -f inet addr show $Iface 2>$null | Out-String)
    if ($out -match 'inet (\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
}

# A table (objects) of every ready device with model, Android OS, API level, IP.
# Usage: adb_list_devices [-Iface <name>]
# Returns: one object per ready device with SERIAL, MODEL, ANDROID, API, IP; nothing when none.
# Output: stderr [WARN] when adb is missing or no device is ready.
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

# Usage: adb_shell -Serial <serial> <command...>
# Returns: the command's output lines; $LASTEXITCODE is adb's exit code.
# Output: stderr [ERROR] usage line when adb, serial or command is missing.
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

# Usage: adb_logcat -Serial <serial> [-Regex <pattern>]
# Returns: the current log buffer lines (only matches with -Regex); nothing without adb or serial.
# Output: none.
function adb_logcat {
    param([string]$Serial, [string]$Regex)
    if (-not (adb_available) -or -not $Serial) { return }
    $out = & adb -s $Serial logcat -d 2>$null
    if ($Regex) { $out | Select-String -Pattern $Regex } else { $out }
}

# Usage: adb_clear_logcat -Serial <serial>
# Returns: nothing; $LASTEXITCODE is adb's exit code.
# Output: none.
function adb_clear_logcat {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return }
    & adb -s $Serial logcat -c 2>$null
}

# --- file transfer ---------------------------------------------------------

# Usage: adb_push -Serial <serial> -LocalPath <path> -RemotePath <path>
# Returns: adb's output lines; $LASTEXITCODE is adb's exit code. Nothing when adb is missing.
# Output: stderr [INFO] the transfer; [ERROR] on missing arguments or local path.
function adb_push {
    param([string]$Serial, [string]$LocalPath, [string]$RemotePath)
    if (-not (adb_available)) { return }
    if (-not $Serial -or -not $LocalPath -or -not $RemotePath) { log_error 'adb_push: need <serial> <local> <remote>'; return }
    if (-not (Test-Path $LocalPath)) { log_error "adb_push: local path not found: $LocalPath"; return }
    log_info "push $LocalPath -> ${Serial}:$RemotePath"
    & adb -s $Serial push $LocalPath $RemotePath
}

# Usage: adb_pull -Serial <serial> -RemotePath <path> [-LocalPath <path>]   (default: .)
# Returns: adb's output lines; $LASTEXITCODE is adb's exit code. Nothing when adb is missing.
# Output: stderr [INFO] the transfer; [ERROR] on missing arguments.
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
# profile the shell cannot subsequently read - on a device with a work profile or
# Samsung Secure Folder the install prints Success and exits 0 while
# `pm list packages` fails with "SecurityException: Shell does not have
# permission to access user <id>". The app is then absent from the launcher and
# unstartable, with every signal saying the install worked.
# Usage: adb_install -Serial <serial> -Apk <path> [-User <id>] [extra adb args...]   (default user 0)
# Returns: $true when adb install exits 0, else $false; nothing when adb is missing or
#   arguments are bad.
# Output: host adb's output; stderr [INFO] the install, [ERROR] on bad arguments.
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
    # Native output goes to the host, not the pipeline, so the caller gets only the result.
    & adb -s $Serial install -r --user $User @ExtraArgs $Apk | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# True when the package is visible to that user. $null when the shell is not
# permitted to query the user at all - which is itself the answer, because a
# package the shell cannot see is a package the launcher will not show.
#
# Call this after adb_install. An installer's exit code asserts that adb accepted
# the command, not that the app is usable.
# Usage: adb_installed_for_user -Serial <serial> -Package <name> [-User <id>]
# Returns: $true/$false whether the package is listed for the user; $null when adb is
#   missing, arguments are bad, or the shell may not query that user.
# Output: stderr [ERROR] on a SecurityException, plus host the device's user list.
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
# Usage: adb_install_verified -Serial <serial> -Apk <path> -Package <name> [-User <id>] [extra adb args...]
# Returns: $true when installed and visible to the user, else $false.
# Output: as adb_install; stderr [ERROR] and host the user list when the package is not visible.
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

# Usage: adb_install_all -Apk <path> [extra adb args...]
# Returns: $true when every ready device installed it (or none is ready), else $false.
# Output: stderr [INFO]/[WARN] per device and a summary line.
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

# Usage: adb_uninstall -Serial <serial> -Package <name>
# Returns: adb's output lines; $LASTEXITCODE is adb's exit code. Nothing when adb is missing.
# Output: stderr [ERROR] on missing arguments.
function adb_uninstall {
    param([string]$Serial, [string]$Package)
    if (-not (adb_available)) { return }
    if (-not $Serial -or -not $Package) { log_error 'adb_uninstall: need <serial> <package>'; return }
    & adb -s $Serial uninstall $Package
}

# --- status ----------------------------------------------------------------

# Usage: adb_battery_level -Serial <serial>
# Returns: the battery level (0-100) as a string; nothing when unknown.
# Output: none.
function adb_battery_level {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return }
    $out = (& adb -s $Serial shell dumpsys battery 2>$null | Out-String)
    if ($out -match '(?m)^\s*level:\s*(\d+)') { return $Matches[1] }
}

# Returns $true (on), $false (off), or $null (unknown).
# Usage: adb_screen_on -Serial <serial>
# Returns: $true (on), $false (off) or $null (unknown).
# Output: none.
function adb_screen_on {
    param([string]$Serial)
    if (-not (adb_available) -or -not $Serial) { return $null }
    $out = (& adb -s $Serial shell dumpsys power 2>$null | Out-String)
    if ($out -match 'Display Power: state=ON|mScreenOn=true|mWakefulness=Awake') { return $true }
    if ($out -match 'Display Power: state=OFF|mScreenOn=false|mWakefulness=(Asleep|Dozing)') { return $false }
    return $null
}

# Usage: adb_device_status -Serial <serial>
# Returns: an object with serial, model, android, battery, screen, wifi_ip; nothing without adb or serial.
# Output: none.
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

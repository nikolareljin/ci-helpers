# Android build / SDK / emulator helpers — PowerShell companion to lib/android.sh.
#
# Split of responsibility matches the Bash side:
#   adb.ps1       devices that exist  — install, logcat, push/pull, properties
#   android.ps1   getting there       — SDK, Gradle build, AVDs, emulators, signing
#   gradle.ps1    the build tool      — wrapper resolution, task invocation
#
# Import-ScriptHelpers loads modules independently, so import what you need:
#   Import-ScriptHelpers logging adb gradle android
#
# Windows difference: SDK tools are .bat/.exe. _Android_ToolNames tries each
# extension, so callers pass the bare name exactly as on the Bash side.

function _Android_IsWindows { return ($IsWindows -or $env:OS -eq 'Windows_NT') }

function _Android_ToolNames {
    param([string]$Name)
    if (_Android_IsWindows) { return @("$Name.bat", "$Name.exe", "$Name.cmd", $Name) }
    return @($Name)
}

# --- SDK -------------------------------------------------------------------

# The Android SDK root, honouring ANDROID_SDK_ROOT then ANDROID_HOME then the
# conventional install paths. $null when none exists.
function android_sdk_root {
    $candidates = @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $HOME 'Android\Sdk'),
        (Join-Path $HOME 'Android/Sdk'),
        (Join-Path $HOME 'Library/Android/sdk'),
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -PathType Container)) { return $c }
    }
    return $null
}

function android_available { return [bool](android_sdk_root) }

# Path to an SDK tool (sdkmanager, avdmanager, emulator, apksigner, adb),
# searching the SDK's several layouts and then PATH. $null when not found.
function android_sdk_tool {
    param([Parameter(Mandatory)][string]$Name)
    $root = android_sdk_root
    if ($root) {
        $dirs = @(
            (Join-Path $root 'cmdline-tools\latest\bin'),
            (Join-Path $root 'cmdline-tools/latest/bin'),
            (Join-Path $root 'cmdline-tools/bin'),
            (Join-Path $root 'tools/bin'),
            (Join-Path $root 'platform-tools'),
            (Join-Path $root 'emulator')
        )
        # build-tools are versioned; prefer the highest.
        $bt = Join-Path $root 'build-tools'
        if (Test-Path $bt) {
            $dirs += (Get-ChildItem $bt -Directory -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending | ForEach-Object { $_.FullName })
        }
        foreach ($d in $dirs) {
            foreach ($n in (_Android_ToolNames $Name)) {
                $p = Join-Path $d $n
                if (Test-Path $p -PathType Leaf) { return $p }
            }
        }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Accept licenses and install platform-tools, the platform and build-tools.
# Idempotent — sdkmanager skips anything already present.
function android_ensure_sdk {
    param([string]$Api = '34', [string]$BuildTools = '34.0.0')
    $sdkmanager = android_sdk_tool 'sdkmanager'
    if (-not $sdkmanager) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) {
            log_error 'android_ensure_sdk: sdkmanager not found. Install the Android command-line tools and set ANDROID_SDK_ROOT.'
        }
        return $false
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info 'android: accepting SDK licenses' }
    # sdkmanager --licenses reads y/n from stdin until it runs out of prompts.
    'y' * 20 -split '' | Where-Object { $_ } | & $sdkmanager --licenses 2>$null | Out-Null
    if (Get-Command log_info -ErrorAction SilentlyContinue) {
        log_info "android: installing platform-tools, platforms;android-$Api, build-tools;$BuildTools"
    }
    & $sdkmanager 'platform-tools' "platforms;android-$Api" "build-tools;$BuildTools"
    return ($LASTEXITCODE -eq 0)
}

# --- build -----------------------------------------------------------------

# A named alias for gradle_run, so Android callers read as Android callers.
function android_gradlew {
    param([string]$Dir, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tasks)
    gradle_run $Dir @Tasks
}

# Assemble an APK or bundle an AAB. One spelling of the debug/release toggle.
function android_build {
    param(
        [string]$Dir = '.',
        [ValidateSet('debug','release')][string]$Variant = 'debug',
        [ValidateSet('apk','aab')][string]$Format = 'apk'
    )
    $prefix = if ($Format -eq 'aab') { 'bundle' } else { 'assemble' }
    # Gradle capitalizes the variant in the task name: assembleDebug, bundleRelease.
    $task = $prefix + $Variant.Substring(0,1).ToUpper() + $Variant.Substring(1)
    gradle_run $Dir $task
}

# The most recently built artifact for a variant. $null when none exists.
function android_artifact {
    param(
        [string]$Dir = '.',
        [ValidateSet('debug','release')][string]$Variant = 'debug',
        [ValidateSet('apk','aab')][string]$Format = 'apk'
    )
    $sub = if ($Format -eq 'aab') { "build/outputs/bundle/$Variant" } else { "build/outputs/apk/$Variant" }
    $hits = Get-ChildItem -Path $Dir -Recurse -Filter "*.$Format" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -replace '\\','/' -like "*$sub/*" } |
            Sort-Object LastWriteTime -Descending
    if ($hits) { return $hits[0].FullName }
    return $null
}

# The application id. Read from the built artifact with aapt/aapt2 when one is
# available, since that is the only source that accounts for applicationIdSuffix
# and flavors; otherwise parsed out of the Gradle build file. $null when neither
# works — a caller that needs a package name should say so rather than guess.
function android_package_name {
    param([string]$Dir = '.', [string]$Artifact)
    if ($Artifact -and (Test-Path $Artifact -PathType Leaf)) {
        $aapt = android_sdk_tool 'aapt2'
        if (-not $aapt) { $aapt = android_sdk_tool 'aapt' }
        if ($aapt) {
            $line = (& $aapt dump badging $Artifact 2>$null | Select-String -Pattern '^package:' | Select-Object -First 1)
            if ($line -and "$line" -match "name='([^']+)'") { return $Matches[1] }
        }
    }
    # applicationIdSuffix is not accounted for here; that is why the artifact is
    # preferred above.
    $hit = Get-ChildItem -Path $Dir -Recurse -Depth 3 -Include 'build.gradle','build.gradle.kts' -ErrorAction SilentlyContinue |
           Select-String -Pattern 'applicationId\s*=?\s*"([^"]+)"' | Select-Object -First 1
    if ($hit -and "$hit" -match 'applicationId\s*=?\s*"([^"]+)"') { return $Matches[1] }
    return $null
}

# --- signing ---------------------------------------------------------------

# Sign an APK or AAB with apksigner (preferred) or jarsigner. The keystore comes
# from a file, or is base64-decoded out of an environment variable for a
# CI-shaped secret. -AllowUnsigned turns a missing keystore into a warning and
# success — the debug-signed fallback that lets a local build proceed without
# release credentials.
function android_sign {
    param(
        [Parameter(Mandatory)][string]$Artifact,
        [string]$Keystore,
        [string]$Base64Env,
        [string]$StorePass = $env:ANDROID_KEYSTORE_PASSWORD,
        [string]$Alias     = $env:ANDROID_KEY_ALIAS,
        [string]$KeyPass   = $env:ANDROID_KEY_PASSWORD,
        [switch]$AllowUnsigned
    )
    if (-not (Test-Path $Artifact -PathType Leaf)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "android_sign: not found: $Artifact" }
        return $false
    }

    $tmpKeystore = $null
    if (-not $Keystore -and $Base64Env) {
        $b64 = [Environment]::GetEnvironmentVariable($Base64Env)
        if (-not $b64) {
            if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "android_sign: `$$Base64Env is empty" }
            return $false
        }
        $tmpKeystore = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllBytes($tmpKeystore, [Convert]::FromBase64String($b64))
        } catch {
            Remove-Item $tmpKeystore -Force -ErrorAction SilentlyContinue
            if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "android_sign: `$$Base64Env is not valid base64" }
            return $false
        }
        $Keystore = $tmpKeystore
    }

    try {
        if (-not $Keystore -or -not (Test-Path $Keystore -PathType Leaf)) {
            if ($AllowUnsigned) {
                if (Get-Command log_warn -ErrorAction SilentlyContinue) {
                    log_warn "android_sign: no keystore — leaving $Artifact as built (debug-signed)."
                }
                return $true
            }
            if (Get-Command log_error -ErrorAction SilentlyContinue) {
                log_error 'android_sign: no keystore. Pass -Keystore, or -Base64Env, or -AllowUnsigned.'
            }
            return $false
        }
        if (-not $Alias) {
            if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'android_sign: need -Alias (or $env:ANDROID_KEY_ALIAS)' }
            return $false
        }
        if (-not $KeyPass) { $KeyPass = $StorePass }

        $apksigner = android_sdk_tool 'apksigner'
        if ($apksigner) {
            if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: signing $Artifact with apksigner" }
            $env:ANDROID_SIGN_STOREPASS = $StorePass
            $env:ANDROID_SIGN_KEYPASS   = $KeyPass
            try {
                & $apksigner sign --ks $Keystore --ks-key-alias $Alias `
                    --ks-pass 'env:ANDROID_SIGN_STOREPASS' --key-pass 'env:ANDROID_SIGN_KEYPASS' $Artifact
                return ($LASTEXITCODE -eq 0)
            } finally {
                Remove-Item Env:\ANDROID_SIGN_STOREPASS -ErrorAction SilentlyContinue
                Remove-Item Env:\ANDROID_SIGN_KEYPASS -ErrorAction SilentlyContinue
            }
        }
        if (Get-Command jarsigner -ErrorAction SilentlyContinue) {
            if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: signing $Artifact with jarsigner (apksigner not found)" }
            & jarsigner -sigalg SHA256withRSA -digestalg SHA-256 `
                -keystore $Keystore -storepass $StorePass -keypass $KeyPass $Artifact $Alias | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error 'android_sign: neither apksigner nor jarsigner is available' }
        return $false
    } finally {
        if ($tmpKeystore) { Remove-Item $tmpKeystore -Force -ErrorAction SilentlyContinue }
    }
}

# --- emulators -------------------------------------------------------------

function android_avd_list {
    $avdmanager = android_sdk_tool 'avdmanager'
    if (-not $avdmanager) { return }
    foreach ($line in (& $avdmanager list avd 2>$null)) {
        if ($line -match '^\s*Name:\s*(.+)$') { Write-Output $Matches[1].Trim() }
    }
}

# Create an AVD if it does not already exist. Requires the matching system image
# — run android_ensure_sdk first.
function android_avd_create {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Api = '34',
        [string]$Abi = 'x86_64'
    )
    $avdmanager = android_sdk_tool 'avdmanager'
    if (-not $avdmanager) { return $false }
    if (@(android_avd_list) -contains $Name) {
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: AVD '$Name' already exists" }
        return $true
    }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: creating AVD '$Name' (api $Api, $Abi)" }
    'no' | & $avdmanager create avd --name $Name --package "system-images;android-$Api;google_apis;$Abi" --force
    return ($LASTEXITCODE -eq 0)
}

# Start an emulator and wait for boot completion. Returns its serial, or $null.
function android_emulator_start {
    param(
        [Parameter(Mandatory)][string]$Avd,
        [switch]$NoWindow,
        [int]$Wait = 180
    )
    $emulator = android_sdk_tool 'emulator'
    if (-not $emulator) { return $null }
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: starting emulator '$Avd'" }

    # $emuArgs, not $args: `Args` is an automatic variable in PowerShell.
    $emuArgs = @('-avd', $Avd, '-no-snapshot-load')
    if ($NoWindow) { $emuArgs += @('-no-window', '-no-audio') }
    Start-Process -FilePath $emulator -ArgumentList $emuArgs -NoNewWindow | Out-Null

    $waited = 0
    while ($waited -lt $Wait) {
        foreach ($serial in @(adb_ready_serials)) {
            if ($serial -notlike 'emulator-*') { continue }
            if ((adb_getprop $serial 'sys.boot_completed') -eq '1') {
                if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: emulator ready as $serial" }
                return $serial
            }
        }
        Start-Sleep -Seconds 3
        $waited += 3
    }
    if (Get-Command log_error -ErrorAction SilentlyContinue) {
        log_error "android_emulator_start: '$Avd' did not report boot completion within ${Wait}s"
    }
    return $null
}

# Stop one emulator, or every running emulator when no serial is given.
function android_emulator_stop {
    param([string]$Serial)
    if (-not (adb_available)) { return $false }
    if ($Serial) {
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: stopping $Serial" }
        & adb -s $Serial emu kill 2>$null | Out-Null
        return $true
    }
    $stopped = 0
    foreach ($s in @(adb_ready_serials)) {
        if ($s -notlike 'emulator-*') { continue }
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "android: stopping $s" }
        & adb -s $s emu kill 2>$null | Out-Null
        $stopped++
    }
    if ($stopped -eq 0 -and (Get-Command log_info -ErrorAction SilentlyContinue)) { log_info 'android: no running emulators' }
    return $true
}

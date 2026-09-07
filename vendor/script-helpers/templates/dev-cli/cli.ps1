# The ./dev entry point — PowerShell companion to cli.sh.
#
# Same verbs, same flags, same behaviour. A developer moving between bash and
# pwsh types the same thing.
#
# Repo-specific behaviour belongs in scripts/project.ps1, which is dot-sourced
# below when it exists. Define Project-<Verb> to replace a verb; anything not
# defined falls back to the shared implementation.

param(
    [Parameter(Position = 0)][string]$Verb,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_bootstrap.ps1')
Import-ScriptHelpers logging manifest changelog

$projectOverrides = Join-Path $PSScriptRoot 'project.ps1'
if (Test-Path $projectOverrides) { . $projectOverrides }

Set-Location $DEV_REPO_ROOT

# --- shared options --------------------------------------------------------

$DEV_TARGET  = ''
$DEV_DEVICE  = ''
$DEV_RELEASE = $false
# Android profile to install into. 0 is the device owner. See Verb-Deploy for
# why this is pinned rather than left to adb's default.
$DEV_USER    = 0
$DEV_ARGS    = @()
$DEV_WANTS_HELP = $false

# $Rest is $null — not an empty array — when no remaining arguments are bound,
# and StrictMode makes $null.Count a terminating error. Normalise once.
$Rest = @($Rest)

$targets = @('android','ios','host','backend','frontend','linux','web','macos','windows')
for ($i = 0; $i -lt $Rest.Count; $i++) {
    switch -Regex ($Rest[$i]) {
        '^--device$'  {
            if ($i + 1 -ge $Rest.Count) { log_error '--device needs a serial, e.g. --device R5CRC2WANMT'; exit 2 }
            $DEV_DEVICE = $Rest[++$i]; continue
        }
        '^--user$'    {
            if ($i + 1 -ge $Rest.Count) { log_error '--user needs a profile id, e.g. --user 0'; exit 2 }
            $DEV_USER = [int]$Rest[++$i]; continue
        }
        '^--release$' { $DEV_RELEASE = $true; continue }
        '^--verbose$' { $VerbosePreference = 'Continue'; continue }
        # Asking a verb for help must not run the verb. Without this,
        # `./dev.ps1 deploy --help` builds and installs on a device.
        '^(-h|--help)$' { $script:DEV_WANTS_HELP = $true; continue }
        default {
            if ($targets -contains $Rest[$i]) { $DEV_TARGET = $Rest[$i] }
            else { $DEV_ARGS += $Rest[$i] }
        }
    }
}

# A verb this repo cannot honour exits 0 with an explanation. It is never simply
# absent: a missing verb is indistinguishable from a typo.
function Not-Applicable {
    param([string]$VerbName, [string]$Reason)
    log_info "${VerbName}: not applicable in this repo — $Reason"
    exit 0
}

# The PowerShell preflight is native — it does not shell out to bash, so this
# works in Windows PowerShell with no Git Bash present.
$script:PreflightPs1 = Join-Path $env:SCRIPT_HELPERS_DIR 'ps/scripts/preflight.ps1'

function Invoke-Preflight {
    param([string[]]$PreflightArgs = @())
    $splat = @{}
    for ($i = 0; $i -lt $PreflightArgs.Count; $i++) {
        switch ($PreflightArgs[$i]) {
            '--quick'          { $splat['Quick'] = $true }
            '--docker'         { $splat['Docker'] = $true }
            '--skip-security'  { $splat['SkipSecurity'] = $true }
            '--list'           { $splat['List'] = $true }
            '--stack'          { $splat['Stack'] = @($PreflightArgs[++$i]) }
            '--dir'            { $splat['Dir'] = $PreflightArgs[++$i] }
        }
    }
    & $script:PreflightPs1 @splat
    return ($LASTEXITCODE -eq 0)
}

function Get-DevProjects {
    $out = & $script:PreflightPs1 -List 2>$null
    if (-not $out) { return @() }
    $out | ForEach-Object {
        $parts = $_ -split "`t"
        if ($parts.Count -ge 2) { [PSCustomObject]@{ Stack = $parts[0]; Dir = $parts[1] } }
    }
}

function Get-StackDir {
    param([string]$Stack)
    $p = Get-DevProjects | Where-Object { $_.Stack -eq $Stack } | Select-Object -First 1
    if ($p) { return $p.Dir }
    return $null
}

function Test-IsFlutter { return ((Test-Path 'pubspec.yaml') -or (Get-StackDir 'flutter')) }
function Test-IsAndroid { return ((Get-StackDir 'gradle') -or (Test-Path 'android')) }

# --- verbs -----------------------------------------------------------------

# Point git at the shared hooks. In a repo that has deleted its build workflows
# the pre-push hook is the only remaining gate, and core.hooksPath lives in
# .git/config — untracked, so a fresh clone has no gate until install sets it.
# setup-hooks.sh is bash; on Windows it ships with Git for Windows.
function Install-DevHooks {
    $setup = Join-Path $env:SCRIPT_HELPERS_DIR 'scripts/setup-hooks.sh'
    if (-not (Test-Path $setup)) {
        log_warn 'install: setup-hooks.sh not found — git hooks not configured'
        return
    }
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        log_warn 'install: bash not found — run "git config core.hooksPath scripts/script-helpers/scripts/git-hooks" by hand'
        return
    }
    & $bash.Source $setup
    if ($LASTEXITCODE -ne 0) { log_warn 'install: could not configure git hooks — pushes will not be gated' }
}

# Install Python dependencies without writing into an externally managed
# interpreter. Mirrors dev_python_install in cli.sh: one project-local .venv,
# the same one local_test_python.sh resolves.
function Install-DevPython {
    param([string]$Dir)
    $py = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' }
          elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' }
          else { $null }
    if (-not $py) { log_warn "install: no python interpreter — skipping $Dir"; return }

    foreach ($v in @('.venv','venv')) {
        foreach ($rel in @("$v/bin/python", "$v/Scripts/python.exe")) {
            $candidate = Join-Path $Dir $rel
            if (Test-Path $candidate) { $py = $candidate; break }
        }
        if ($py -ne 'python3' -and $py -ne 'python') { break }
    }

    if ($py -eq 'python3' -or $py -eq 'python') {
        & $py -c 'import os,sys,sysconfig; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"),"EXTERNALLY-MANAGED")) else 1)' 2>$null
        if ($LASTEXITCODE -eq 0) {
            log_info "install: system Python is externally managed (PEP 668); using $Dir/.venv"
            & $py -m venv (Join-Path $Dir '.venv')
            $venvPy = @("$Dir/.venv/bin/python", "$Dir/.venv/Scripts/python.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $venvPy) { log_error "install: could not create $Dir/.venv"; exit 1 }
            $py = $venvPy
        }
    }

    $req = Join-Path $Dir 'requirements.txt'
    if (Test-Path $req) {
        log_info "install: $py -m pip install -r $req"
        & $py -m pip install -r $req --quiet
    }
    $proj = Join-Path $Dir 'pyproject.toml'
    # Installed by path rather than by Push-Location: $py may be relative to the
    # repo root, and changing directory would break it.
    if ((Test-Path $proj) -and (Select-String -Path $proj -Pattern '^\s*dev\s*=' -Quiet)) {
        log_info "install: $py -m pip install -e '$Dir[dev]'"
        & $py -m pip install -e "$Dir[dev]" --quiet
        if ($LASTEXITCODE -ne 0) { log_warn 'install: the dev extra did not install; continuing' }
    }
}

function Verb-Install {
    if (Get-Command Project-Install -ErrorAction SilentlyContinue) { Project-Install; return }
    log_info 'install: submodules'
    & git submodule update --init --recursive
    Install-DevHooks
    if (Test-IsFlutter) {
        Import-ScriptHelpers flutter
        $d = Get-StackDir 'flutter'; if (-not $d) { $d = '.' }
        flutter_pub_get $d | Out-Null
    }
    $pyDir = Get-StackDir 'python'
    if ($pyDir) { Install-DevPython $pyDir }
    $nodeDir = Get-StackDir 'node'
    if ($nodeDir) {
        log_info "install: npm ci in $nodeDir"
        Push-Location $nodeDir
        try { & npm ci } finally { Pop-Location }
    }
}

function Verb-Build {
    if (Get-Command Project-Build -ErrorAction SilentlyContinue) { Project-Build; return }
    $mode = if ($DEV_RELEASE) { 'release' } else { 'debug' }
    if (Test-IsFlutter) {
        Import-ScriptHelpers flutter
        $d = Get-StackDir 'flutter'; if (-not $d) { $d = '.' }
        $target = if ($DEV_TARGET -eq 'ios') { 'ios' } else { 'apk' }
        flutter_build -Target $target -Dir $d -Mode $mode | Out-Null
        return
    }
    if (Test-IsAndroid) {
        Import-ScriptHelpers gradle android
        $d = Get-StackDir 'gradle'; if (-not $d) { $d = '.' }
        android_build -Dir $d -Variant $mode -Format apk | Out-Null
        return
    }
    Not-Applicable 'build' 'no Flutter or Gradle project detected'
}

function Verb-Run {
    if (Get-Command Project-Run -ErrorAction SilentlyContinue) { Project-Run; return }
    if (Test-IsFlutter) {
        Import-ScriptHelpers flutter
        $d = Get-StackDir 'flutter'; if (-not $d) { $d = '.' }
        $id = flutter_resolve_device $DEV_DEVICE $d
        if (-not $id) { exit 1 }
        flutter_run_cmd $d 'run' '-d' $id | Out-Null
        return
    }
    Not-Applicable 'run' 'no runnable target — use ./dev deploy to install on a device'
}

function Verb-Test {
    if (Get-Command Project-Test -ErrorAction SilentlyContinue) { Project-Test; return }
    if (-not (Invoke-Preflight @('--quick','--skip-security'))) { exit 1 }
}

function Verb-Preflight {
    if (Get-Command Project-Preflight -ErrorAction SilentlyContinue) { Project-Preflight; return }
    if (-not (Invoke-Preflight $DEV_ARGS)) { exit 1 }
}

function Verb-Deploy {
    if (Get-Command Project-Deploy -ErrorAction SilentlyContinue) { Project-Deploy; return }
    Import-ScriptHelpers adb gradle android
    $mode = if ($DEV_RELEASE) { 'release' } else { 'debug' }
    $serial = $DEV_DEVICE
    if (-not $serial) {
        $serials = @(adb_ready_serials)
        if ($serials.Count -ne 1) {
            log_error "deploy: $($serials.Count) devices ready — pass --device <serial>"
            adb_list_devices | Format-Table | Out-String | Write-Host
            exit 1
        }
        $serial = $serials[0]
    }
    $d = Get-StackDir 'gradle'; if (-not $d) { $d = '.' }
    if (Test-IsFlutter) {
        Import-ScriptHelpers flutter
        $fd = Get-StackDir 'flutter'; if (-not $fd) { $fd = '.' }
        flutter_build -Target apk -Dir $fd -Mode $mode | Out-Null
    } else {
        android_build -Dir $d -Variant $mode -Format apk | Out-Null
    }
    $artifact = android_artifact -Dir $d -Variant $mode -Format apk
    if (-not $artifact) { log_error "deploy: no APK found for variant $mode"; exit 1 }

    # Install into an explicit user, then confirm the package is actually visible
    # there. `adb install` can report Success into a work profile or Secure Folder
    # the shell cannot read back, leaving the app absent from the launcher while
    # every signal says the install worked.
    $pkg = android_package_name -Dir $d -Artifact $artifact
    if ($pkg) {
        if (-not (adb_install_verified -Serial $serial -Apk $artifact -Package $pkg -User $DEV_USER)) { exit 1 }
    } else {
        log_warn 'deploy: could not determine the package name — installing without the post-install check.'
        log_warn "deploy: confirm by hand with: adb -s $serial shell pm list packages --user $DEV_USER"
        if (-not (adb_install -Serial $serial -Apk $artifact -User $DEV_USER)) { exit 1 }
    }
}

function Verb-Devices {
    if (Get-Command Project-Devices -ErrorAction SilentlyContinue) { Project-Devices; return }
    Import-ScriptHelpers adb gradle android
    Write-Host 'Android devices:'
    adb_list_devices | Format-Table | Out-String | Write-Host
    Write-Host 'Android AVDs:'
    $avds = @(android_avd_list)
    if ($avds.Count -eq 0) { Write-Host '  (none, or no SDK)' } else { $avds | ForEach-Object { Write-Host "  $_" } }
    # $IsMacOS does not exist in Windows PowerShell 5.1, and StrictMode makes a
    # bare reference to it a terminating error. There is also no ps/lib/ios.ps1
    # yet, so the listing is conditional on the helper actually being loadable.
    $onMac = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
    if ($onMac) {
        # Import-ScriptHelpers throws on an unknown module and takes no
        # -ErrorAction (it is a plain function, and ValueFromRemainingArguments
        # would swallow the flag as a module name).
        try { Import-ScriptHelpers ios } catch { }
        Write-Host ''
        Write-Host 'iOS simulators (booted):'
        if (Get-Command ios_booted_simulators -ErrorAction SilentlyContinue) {
            $sims = @(ios_booted_simulators)
            if ($sims.Count -eq 0) { Write-Host '  (none)' } else { $sims | ForEach-Object { Write-Host "  $_" } }
        } else {
            Write-Host '  (no PowerShell ios module — use ./dev devices from bash)'
        }
    }
}

function Verb-Screenshot {
    if (Get-Command Project-Screenshot -ErrorAction SilentlyContinue) { Project-Screenshot; return }
    Import-ScriptHelpers adb screencap
    $out = $null
    for ($i = 0; $i -lt $DEV_ARGS.Count; $i++) {
        if ($DEV_ARGS[$i] -eq '--out') { $out = $DEV_ARGS[++$i] }
    }
    $path = screencap_shot -Device $DEV_DEVICE -Platform $DEV_TARGET -Out $out
    if (-not $path) { exit 1 }
}

function Verb-Record {
    if (Get-Command Project-Record -ErrorAction SilentlyContinue) { Project-Record; return }
    Import-ScriptHelpers adb screencap
    $out = $null; $seconds = 30; $gif = $false
    for ($i = 0; $i -lt $DEV_ARGS.Count; $i++) {
        switch ($DEV_ARGS[$i]) {
            '--out'     { $out = $DEV_ARGS[++$i] }
            '--seconds' { $seconds = [int]$DEV_ARGS[++$i] }
            '--gif'     { $gif = $true }
        }
    }
    $path = screencap_record -Device $DEV_DEVICE -Platform $DEV_TARGET -Out $out -Seconds $seconds -Gif:$gif
    if (-not $path) { exit 1 }
}

function Verb-Logs {
    if (Get-Command Project-Logs -ErrorAction SilentlyContinue) { Project-Logs; return }
    Import-ScriptHelpers adb
    $serial = $DEV_DEVICE
    if (-not $serial) {
        $serials = @(adb_ready_serials)
        if ($serials.Count -lt 1) { log_error 'logs: no device ready'; exit 1 }
        $serial = $serials[0]
    }
    log_info "logs: streaming from $serial (Ctrl-C to stop)"
    & adb -s $serial logcat
}

function Verb-Clean {
    if (Get-Command Project-Clean -ErrorAction SilentlyContinue) { Project-Clean; return }
    if (Test-IsFlutter) {
        Import-ScriptHelpers flutter
        $d = Get-StackDir 'flutter'; if (-not $d) { $d = '.' }
        flutter_run_cmd $d 'clean' | Out-Null
    }
    $g = Get-StackDir 'gradle'
    if ($g) { Import-ScriptHelpers gradle; gradle_clean $g | Out-Null }
    log_info 'clean: done. User data and .env files are untouched.'
}

function Verb-Update {
    if (Get-Command Project-Update -ErrorAction SilentlyContinue) { Project-Update; return }
    log_info 'update: syncing submodules to their tracked branches'
    & git submodule sync --recursive
    & git submodule update --init --remote --recursive
    if ($LASTEXITCODE -ne 0) {
        log_warn 'update: --remote failed; falling back to the pinned commits'
        & git submodule update --init --recursive
    }
}

function Verb-Release {
    if (Get-Command Project-Release -ErrorAction SilentlyContinue) { Project-Release; return }
    if ($DEV_ARGS.Count -lt 1) { log_error 'release: need a version, e.g. ./dev release 1.4.0'; exit 2 }
    $version = $DEV_ARGS[0]
    manifest_sync_version -Dir '.' -Version $version | Out-Null
    changelog_new_section -File 'CHANGELOG.md' -Version $version | Out-Null
    log_info "release: manifests and CHANGELOG updated for $version."
    log_info "release: review the changes, then commit on a release/$version branch."
    log_info 'release: this does NOT tag or push. Tagging happens on merge.'
}

# --- dispatch --------------------------------------------------------------

function Show-Usage {
    Write-Host @'
Usage: ./dev <verb> [target] [options]

Core
  install       Install dependencies and initialize submodules. Idempotent.
  build         Produce artifacts. Never starts anything.
  run           Start the app in the foreground.
  test          Run the test suite.
  preflight     Run every check CI would have run. The pre-push hook calls this.
  deploy        Build, then install and launch on a connected device.
  clean         Remove build output and caches. Never touches user data.
  update        Sync submodules and refresh pinned dependencies.

Mobile
  devices       List connected devices, emulators, AVDs and simulators.
  screenshot    Capture a PNG from a device.        [--out <path>]
  record        Capture screen video.               [--seconds <n>] [--gif]
  logs          Stream filtered device logs.
  release       Bump the version across manifests and open a CHANGELOG section.

Targets   android ios host backend frontend linux web macos windows
Options   --device <id>  --user <id>  --release  --verbose

--user is the Android profile to install into, default 0 (the device owner).
deploy verifies the package is visible there afterwards: an unqualified install
can succeed into a work profile or Secure Folder the shell cannot read back,
leaving the app absent from the launcher while adb reports Success.
List profiles with: adb shell pm list users

Captured media defaults to docs/screenshots/. Override with $env:SCREENCAP_DIR.
'@
}

if ($DEV_WANTS_HELP) { Show-Usage; exit 0 }

switch ($Verb) {
    ''           { Show-Usage; exit 0 }
    $null        { Show-Usage; exit 0 }
    'help'       { Show-Usage; exit 0 }
    '-h'         { Show-Usage; exit 0 }
    '--help'     { Show-Usage; exit 0 }
    'install'    { Verb-Install }
    'build'      { Verb-Build }
    'run'        { Verb-Run }
    'test'       { Verb-Test }
    'preflight'  { Verb-Preflight }
    'deploy'     { Verb-Deploy }
    'devices'    { Verb-Devices }
    'screenshot' { Verb-Screenshot }
    'record'     { Verb-Record }
    'logs'       { Verb-Logs }
    'clean'      { Verb-Clean }
    'update'     { Verb-Update }
    'release'    { Verb-Release }
    default {
        Write-Host "Unknown verb: $Verb"
        Write-Host ''
        Show-Usage
        exit 2
    }
}

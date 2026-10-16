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

# $Rest is $null -- not an empty array -- when no remaining arguments are bound,
# and StrictMode makes $null.Count a terminating error. Normalise once. Not
# @($Rest) alone: @($null) is an array holding one $null, which every verb then
# saw as an empty argument (`./dev.ps1 start` passed '' on to svc_start).
$Rest = @($Rest | Where-Object { $null -ne $_ })

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

# A verb this repo cannot honour exits 3 with an explanation. It is never simply
# absent: a missing verb is indistinguishable from a typo. Not 0: a skipped
# build or deploy must not read as one that ran (R-765 ADR-0061).
function Not-Applicable {
    param([string]$VerbName, [string]$Reason)
    log_info "${VerbName}: not applicable in this repo -- $Reason"
    exit 3
}

# The service verbs are lib/service.sh's, one implementation: a repository
# that declares SVC_BACKEND in scripts/project.sh runs them through bash (Git
# Bash on Windows) and scripts/cli.sh.
function Test-DevHasServices {
    $projectSh = Join-Path $PSScriptRoot 'project.sh'
    if (-not (Test-Path $projectSh)) { return $false }
    return [bool](Select-String -Path $projectSh -Pattern '^\s*(export\s+)?SVC_BACKEND=' -Quiet)
}
function Invoke-ServiceVerb {
    param([string]$VerbName)
    $bash = Find-DevBash
    if (-not $bash) {
        log_error "${VerbName}: this repository's services run through bash (not WSL's); install Git for Windows (Git Bash)"
        exit 1
    }
    & $bash (Join-Path $PSScriptRoot 'cli.sh') $VerbName @Rest
    exit $LASTEXITCODE
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
            '--security-only'  { $splat['SecurityOnly'] = $true }
            '--list'           { $splat['List'] = $true }
            '--stack'          { $splat['Stack'] = @($PreflightArgs[++$i]) }
            '--dir'            { $splat['Dir'] = $PreflightArgs[++$i] }
        }
    }
    & $script:PreflightPs1 @splat
    return ($LASTEXITCODE -eq 0)
}

function Get-DevProjects {
    # preflight refuses to run where CI=true, and under ErrorActionPreference
    # Stop that refusal ended ./dev.ps1: build, deploy and every verb that
    # detects a stack failed on any CI runner. -List only reads the tree, so CI
    # is cleared for it alone, as cli.sh does (CI="" preflight.sh --list).
    $savedCI = $env:CI
    $env:CI = ''
    try { $out = & $script:PreflightPs1 -List 2>$null } finally { $env:CI = $savedCI }
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
# A bash that can run this repository's scripts. On Windows the first `bash`
# on PATH is often WSL's (System32, WindowsApps), which cannot read a Windows
# path; Git Bash can. Returns its path, or $null.
function Find-DevBash {
    foreach ($c in @(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($c.Source -notmatch '[\\/](System32|WindowsApps)[\\/]') { return $c.Source }
    }
    foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
                     "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Install-DevHooks {
    $setup = Join-Path $env:SCRIPT_HELPERS_DIR 'scripts/setup-hooks.sh'
    if (-not (Test-Path $setup)) {
        log_warn 'install: setup-hooks.sh not found — git hooks not configured'
        return
    }
    $bash = Find-DevBash
    if (-not $bash) {
        log_warn 'install: bash not found — run "git config core.hooksPath scripts/script-helpers/scripts/git-hooks" by hand'
        return
    }
    & $bash $setup
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

# The secret and dependency scan alone; see verb_scan in cli.sh.
function Verb-Scan {
    if (Get-Command Project-Scan -ErrorAction SilentlyContinue) { Project-Scan; return }
    if (-not (Invoke-Preflight (@('--security-only') + @($DEV_ARGS)))) { exit 1 }
}

# Browser end-to-end tests with Playwright; see verb_e2e in cli.sh.
function Verb-E2e {
    if (Get-Command Project-E2e -ErrorAction SilentlyContinue) { Project-E2e; return }
    # What git sees: tracked files and untracked ones it does not ignore, so not
    # node_modules and not submodule contents; see verb_e2e in cli.sh.
    $inGit = $false
    & git -C $DEV_REPO_ROOT rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) { $inGit = $true }
    # A tracked config deleted from the work tree is still listed: keep the ones
    # that exist. One run per directory, even with .ts and .js side by side.
    # -z: without it git quotes a path with non-ASCII characters.
    $configs = @(if ($inGit) {
        ((& git -C $DEV_REPO_ROOT ls-files -z --cached --others --exclude-standard) -join "`n") -split "`0" |
            Where-Object { $_ -match '(^|/)playwright\.config\.[^/]+$' } |
            ForEach-Object { Join-Path $DEV_REPO_ROOT $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            ForEach-Object { Get-Item -LiteralPath $_ }
    } else {
        Get-ChildItem -Path $DEV_REPO_ROOT -Recurse -File -Filter 'playwright.config.*' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' }
    })
    $dirs = @($configs | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
    if ($dirs.Count -eq 0) { Not-Applicable 'e2e' 'no playwright.config.* found; define Project-E2e in scripts/project.ps1' }
    if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { log_error 'e2e: npx not found; install Node.js'; exit 1 }
    $failed = $false
    $root = (Get-Item -LiteralPath $DEV_REPO_ROOT).FullName
    foreach ($dir in $dirs) {
        $rel = $dir.Substring([Math]::Min($root.Length, $dir.Length)).TrimStart('\', '/'); if (-not $rel) { $rel = '.' }
        $pkg = Join-Path $dir 'package.json'
        if (-not ((Test-Path -LiteralPath $pkg) -and (Select-String -LiteralPath $pkg -Pattern '"(@playwright/test|playwright)"\s*:' -Quiet))) {
            log_info "e2e: skipping ${rel}: its package.json does not depend on Playwright"
            continue
        }
        log_info "e2e: $rel"
        # Node resolves packages upward, and a workspace install hoists them to
        # the root: look in every node_modules from here up to the repository root.
        $found = $false; $up = $dir
        while ($up) {
            if ((Test-Path -LiteralPath (Join-Path $up 'node_modules/@playwright/test')) -or (Test-Path -LiteralPath (Join-Path $up 'node_modules/playwright'))) { $found = $true; break }
            if ($up -eq $root -or -not $up.StartsWith($root)) { break }
            $up = Split-Path -Parent $up
        }
        if (-not $found) {
            log_error "e2e: Playwright is not installed in $rel; run ./dev install first"
            $failed = $true
            continue
        }
        Push-Location -LiteralPath $dir
        try {
            $browsers = @(); if ($env:PLAYWRIGHT_BROWSERS) { $browsers = @($env:PLAYWRIGHT_BROWSERS -split '\s+' | Where-Object { $_ }) }
            & npx playwright install @browsers
            if ($LASTEXITCODE -ne 0) { $failed = $true; continue }
            $extra = @($DEV_ARGS | Where-Object { $_ })
            & npx playwright test @extra
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        } finally { Pop-Location }
    }
    if ($failed) { exit 1 }
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

# Stop running services without removing them or their data; see verb_stop in cli.sh.
function Verb-Start {
    if (Get-Command Project-Start -ErrorAction SilentlyContinue) { Project-Start; return }
    if (Test-DevHasServices) { Invoke-ServiceVerb 'start' }
    Not-Applicable 'start' 'no services declared; set SVC_BACKEND in scripts/project.sh or define Project-Start in scripts/project.ps1'
}
function Verb-Restart {
    if (Get-Command Project-Restart -ErrorAction SilentlyContinue) { Project-Restart; return }
    if (Test-DevHasServices) { Invoke-ServiceVerb 'restart' }
    if ((Get-Command Project-Stop -ErrorAction SilentlyContinue) -and (Get-Command Project-Start -ErrorAction SilentlyContinue)) {
        Project-Stop; Project-Start; return
    }
    Not-Applicable 'restart' 'no services declared; set SVC_BACKEND in scripts/project.sh or define Project-Restart in scripts/project.ps1'
}
function Verb-Status {
    if (Get-Command Project-Status -ErrorAction SilentlyContinue) { Project-Status; return }
    if (Test-DevHasServices) { Invoke-ServiceVerb 'status' }
    Not-Applicable 'status' 'no services declared; set SVC_BACKEND in scripts/project.sh or define Project-Status in scripts/project.ps1'
}
function Verb-Stop {
    if (Get-Command Project-Stop -ErrorAction SilentlyContinue) { Project-Stop; return }
    if (Test-DevHasServices) { Invoke-ServiceVerb 'stop' }
    foreach ($f in @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')) {
        $path = Join-Path $DEV_REPO_ROOT $f
        if (Test-Path $path) {
            # The same choice as get_docker_compose_cmd in lib/docker.sh: the plugin,
            # then the standalone docker-compose, else a clear error.
            $useStandalone = $false
            $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
            if ($dockerCmd) { & docker compose version *> $null }
            if (-not $dockerCmd -or $LASTEXITCODE -ne 0) {
                if (Get-Command docker-compose -ErrorAction SilentlyContinue) { $useStandalone = $true }
                else { log_error "stop: neither 'docker compose' nor 'docker-compose' found"; exit 1 }
            }
            log_info "stop: stopping the compose stack in $f; containers and volumes are kept"
            if ($useStandalone) { & docker-compose -f $path stop } else { & docker compose -f $path stop }
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            return
        }
    }
    Not-Applicable 'stop' 'no compose file; set SVC_BACKEND in scripts/project.sh or define Project-Stop in scripts/project.ps1'
}

function Verb-Logs {
    # logs android / logs ios stay device logs, whatever else the repo runs.
    if ($DEV_TARGET -ne 'android' -and $DEV_TARGET -ne 'ios') {
        if (Get-Command Project-Logs -ErrorAction SilentlyContinue) { Project-Logs; return }
        if (Test-DevHasServices) { Invoke-ServiceVerb 'logs' }
    }
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

function Verb-Signing {
    if ($DEV_ARGS.Count -ne 2 -or $DEV_ARGS[0] -ne 'android-keystore' -or -not $DEV_ARGS[1]) {
        log_error 'signing: usage: ./dev signing android-keystore <output.jks>'
        exit 2
    }
    Import-ScriptHelpers android
    if (-not (android_generate_keystore -OutputPath $DEV_ARGS[1])) { exit 1 }
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
  scan          Secret and dependency scan only (gitleaks, audits).  [--docker]
  e2e           Browser tests with Playwright, where playwright.config.* exists.
  deploy        Build, then install and launch on a connected device.
  clean         Remove build output and caches. Never touches user data.
  update        Sync submodules and refresh pinned dependencies.

Services   (scripts/project.sh: SVC_BACKEND, SVC_* -- run through Git Bash)
  start         Start in the background, wait until ready, print the URLs.
  stop          Stop what start or run started. Keeps data; nothing running is ok.
  restart       Stop, then start.
  status        What runs, which ports listen, health.
  logs [name]   Follow service logs. `logs android|ios` streams device logs.

Mobile
  devices       List connected devices, emulators, AVDs and simulators.
  screenshot    Capture a PNG from a device.        [--out <path>]
  record        Capture screen video.               [--seconds <n>] [--gif]
  signing       Create a local signing credential.  [android-keystore <output.jks>]
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

# The repository's own verbs: Project-* functions that are not overrides.
function Show-RepoVerbs {
    $standard = @('install','build','run','start','stop','restart','status','test','preflight','scan','e2e','deploy','devices','screenshot','record','logs','clean','update','signing','release')
    $own = @(Get-Command -Name 'Project-*' -CommandType Function -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name.Substring(8).ToLower() } | Where-Object { $standard -notcontains $_ })
    if ($own.Count -gt 0) {
        Write-Host ''
        Write-Host 'This repository (scripts/project.ps1)'
        $own | ForEach-Object { Write-Host "  $_" }
    }
}

# --help for a verb of the repository's own is that verb's to answer, as in cli.sh.
$repoVerb = ($Verb -match '^[a-z][a-z0-9-]*$') -and (Get-Command "Project-$Verb" -ErrorAction SilentlyContinue) -and
    (@('install','build','run','start','stop','restart','status','test','preflight','scan','e2e','deploy','devices','screenshot','record','logs','clean','update','signing','release') -notcontains $Verb)
if ($DEV_WANTS_HELP -and -not $repoVerb) { Show-Usage; Show-RepoVerbs; exit 0 }

switch ($Verb) {
    ''           { Show-Usage; Show-RepoVerbs; exit 0 }
    $null        { Show-Usage; Show-RepoVerbs; exit 0 }
    'help'       { Show-Usage; Show-RepoVerbs; exit 0 }
    '-h'         { Show-Usage; Show-RepoVerbs; exit 0 }
    '--help'     { Show-Usage; Show-RepoVerbs; exit 0 }
    'install'    { Verb-Install }
    'build'      { Verb-Build }
    'run'        { Verb-Run }
    'start'      { Verb-Start }
    'stop'       { Verb-Stop }
    'restart'    { Verb-Restart }
    'status'     { Verb-Status }
    'test'       { Verb-Test }
    'preflight'  { Verb-Preflight }
    'scan'       { Verb-Scan }
    'e2e'        { Verb-E2e }
    'deploy'     { Verb-Deploy }
    'devices'    { Verb-Devices }
    'screenshot' { Verb-Screenshot }
    'record'     { Verb-Record }
    'logs'       { Verb-Logs }
    'clean'      { Verb-Clean }
    'update'     { Verb-Update }
    'signing'    { Verb-Signing }
    'release'    { Verb-Release }
    default {
        # A verb of the repository's own: Project-<Verb> in scripts/project.ps1,
        # given its arguments as typed.
        if ($Verb -match '^[a-z][a-z0-9-]*$' -and (Get-Command "Project-$Verb" -ErrorAction SilentlyContinue)) {
            # A PowerShell function, not a program: $LASTEXITCODE may be unset
            # (StrictMode makes reading it an error). A failure throws, which
            # $ErrorActionPreference = 'Stop' turns into a non-zero exit.
            & "Project-$Verb" @Rest
            exit 0
        }
        Write-Host "Unknown verb: $Verb"
        Write-Host ''
        Show-Usage
        exit 2
    }
}

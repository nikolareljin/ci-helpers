# Behaviour tests for templates/dev-cli/cli.ps1, the PowerShell ./dev.
#
# CI parsed only ps/, never the template, and nothing ran it. This drives it in
# a scratch repository: exit codes (2 unknown, 3 not applicable), a verb of the
# repository's own, and the service verbs handed to bash and lib/service.sh.
#
# Usage: pwsh -NoProfile -File ps/tests/dev_cli_template_test.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

$script:failures = 0
function note([string]$m) { Write-Host "[dev_cli_template_test.ps1]   ok  $m" }
function fail([string]$m) { Write-Host "[dev_cli_template_test.ps1][ERROR] $m"; $script:failures++ }
# $r, when given, is a dev run: its output is printed on a failure, which is
# where the reason is.
function check([string]$what, $want, $got, $r = $null) {
    if ("$want" -eq "$got") { note $what; return }
    fail "${what}: expected [$want], got [$got]"
    if ($r) { Write-Host "    output: $($r.out)" }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("devcli-ps-" + [guid]::NewGuid())
$repo = Join-Path $tmp 'repo'
New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
try {
    & git -C $repo init -q . | Out-Null
    foreach ($f in 'cli.ps1', '_bootstrap.ps1', 'cli.sh', '_bootstrap.sh') {
        Copy-Item (Join-Path $root "templates/dev-cli/$f") (Join-Path $repo 'scripts')
    }
    Copy-Item (Join-Path $root 'templates/dev-cli/dev.ps1') $repo
    $env:SCRIPT_HELPERS_DIR = $root

    # Each run is a fresh pwsh, as a person runs it; its exit code is the result.
    function dev([string[]]$a) {
        $out = & pwsh -NoProfile -File (Join-Path $repo 'dev.ps1') @a 2>&1 | Out-String
        return @{ rc = $LASTEXITCODE; out = $out }
    }

    $r = dev @()
    check './dev.ps1 alone shows the verbs and exits 0' 0 $r.rc $r
    if ($r.out -notmatch 'Services') { fail "the verb list has no Services section: $($r.out)" } else { note 'the verb list has the service verbs' }
    $r = dev @('bogus')
    check './dev.ps1 bogus exits 2' 2 $r.rc $r
    $r = dev @('build')
    check 'build with nothing to build is not applicable (3)' 3 $r.rc $r
    # CI=true is where preflight refuses to run; stack detection must still work.
    $env:CI = 'true'
    $r = dev @('build')
    $env:CI = $null
    check 'build with CI=true: still detected and not applicable (3), not an error' 3 $r.rc $r
    foreach ($v in 'start', 'restart', 'status', 'stop') {
        $r = dev @($v)
        check "$v with no services is not applicable (3)" 3 $r.rc $r
    }

    Set-Content -Path (Join-Path $repo 'scripts/project.ps1') -Value @(
        'function Project-Hello { Write-Host "hello: $($args -join '' '')" }'
    )
    $r = dev @('hello', 'a', '--b')
    check './dev.ps1 hello runs Project-Hello and exits 0' 0 $r.rc $r
    if ($r.out -notmatch 'hello: a --b') { fail "Project-Hello did not get its arguments as typed: $($r.out)" } else { note 'with its arguments as typed' }
    $r = dev @('hello', '--help')
    if ($r.out -notmatch 'hello: --help') { fail "--help after a repository verb went to the template, not the verb: $($r.out)" } else { note "--help after a repository verb is that verb's" }
    $r = dev @('--help')
    if ($r.out -notmatch '(?m)^  hello') { fail "--help does not list the repository's verb: $($r.out)" } else { note "--help lists the repository's own verbs" }

    # keytool prompts in the real command. A stub keeps this CI test
    # non-interactive while checking the CLI reaches it with JKS arguments.
    $bin = Join-Path $tmp 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    if ($env:OS -eq 'Windows_NT') {
        $keytool = Join-Path $bin 'keytool.cmd'
        Set-Content -Path $keytool -Value "@echo off`r`necho %* > `"%KEYTOOL_ARGS%`"" -Encoding ascii
    } else {
        $keytool = Join-Path $bin 'keytool'
        Set-Content -Path $keytool -Value @'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$KEYTOOL_ARGS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-keystore' ]; then
    : > "$2"
    break
  fi
  shift
done
'@ -NoNewline
        & chmod +x $keytool
    }
    $savedPath = $env:PATH
    $savedKeytoolArgs = $env:KEYTOOL_ARGS
    $argsFile = Join-Path $tmp 'keytool.args'
    $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$env:PATH"
    $env:KEYTOOL_ARGS = $argsFile
    try {
        $output = Join-Path (Join-Path $tmp 'credentials') 'release.jks'
        $r = dev @('signing', 'android-keystore', $output)
        check 'signing android-keystore exits 0' 0 $r.rc $r
        $keytoolArgs = if (Test-Path $argsFile) { Get-Content $argsFile } else { @() }
        if ($keytoolArgs -contains '-storetype' -and $keytoolArgs -contains 'JKS') {
            note 'signing android-keystore passes the JKS store type'
        } else {
            fail "signing android-keystore did not invoke keytool for JKS: $($keytoolArgs -join ' ')"
        }
        if ($env:OS -ne 'Windows_NT' -and (Test-Path -LiteralPath $output -PathType Leaf)) {
            note 'signing creates the requested keystore path'
        } elseif ($env:OS -ne 'Windows_NT') {
            fail 'signing did not create the requested keystore path'
        } else {
            note 'SKIP generated keystore assertion: cmd stub records arguments only'
        }
        $r = dev @('signing', 'android-keystore')
        check 'signing without an output exits 2' 2 $r.rc $r
    } finally {
        $env:PATH = $savedPath
        $env:KEYTOOL_ARGS = $savedKeytoolArgs
    }

    # Services are lib/service.sh's: with SVC_BACKEND in project.sh, through bash.
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        New-Item -ItemType SymbolicLink -Path (Join-Path $repo 'scripts/script-helpers') -Target $root | Out-Null
        Set-Content -Path (Join-Path $repo 'scripts/project.sh') -Value @(
            'export SVC_BACKEND=proc',
            'SVC_PROCS=("web:sleep 300")'
        )
        $r = dev @('status')
        check 'status of a stopped proc service, through bash: 1' 1 $r.rc $r
        if ($r.out -notmatch 'web: stopped') { fail "status was not lib/service.sh's: $($r.out)" } else { note "status is lib/service.sh's" }
        # A WSL-like bash first on PATH (a System32 directory) must be passed over.
        $wsl = Join-Path $tmp 'System32'
        New-Item -ItemType Directory -Path $wsl -Force | Out-Null
        Set-Content -Path (Join-Path $wsl 'bash') -Value "#!/bin/sh`necho WSL-BASH; exit 42"
        & chmod +x (Join-Path $wsl 'bash')
        $savedPath = $env:PATH
        $env:PATH = "$wsl$([System.IO.Path]::PathSeparator)$env:PATH"
        $r = dev @('status')
        $env:PATH = $savedPath
        check 'a System32 bash first on PATH is passed over' 1 $r.rc $r
        if ($r.out -match 'WSL-BASH') { fail "the System32 bash ran: $($r.out)" } else { note 'and it did not run' }
        $r = dev @('start')
        check 'start through bash: 0 (no phantom empty argument)' 0 $r.rc $r
        $r = dev @('stop')
        check 'stop through bash: 0' 0 $r.rc $r
        if ($r.out -notmatch 'stopped web') { fail "stop did not stop the service: $($r.out)" } else { note 'stop stopped it' }
    } else {
        note 'SKIP service verbs: no bash'
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { Write-Host "[dev_cli_template_test.ps1] FAILED: $script:failures"; exit 1 }
Write-Host '[dev_cli_template_test.ps1] ALL PASSED'
exit 0

# Behaviour tests for ps/lib/ollama_install.ps1.
#
# The download is stubbed (Invoke-WebRequest writes a local zip), and winget is a
# function, so nothing is fetched or installed. What is checked: winget first,
# the zip checked against the pin before it is unpacked, a mismatch unpacks
# nothing, an installed pinned version is left alone.
#
# Usage: pwsh -NoProfile -File ps/tests/ollama_install_test.ps1
$ErrorActionPreference = 'Stop'
$lib = Join-Path (Join-Path $PSScriptRoot '..') 'lib'
. (Join-Path $lib 'logging.ps1')
. (Join-Path $lib 'ollama_install.ps1')

$script:failures = 0
function note([string]$m) { Write-Host "[ollama_install_test.ps1] $m" }
function check([string]$label, $want, $got) {
    if ("$want" -eq "$got") { note "  ok  $label" } else { Write-Host "[ollama_install_test.ps1][ERROR] ${label}: expected [$want], got [$got]"; $script:failures++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ollama-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $tmp 'src/lib/ollama') -Force | Out-Null
Set-Content -Path (Join-Path $tmp 'src/ollama.exe') -Value 'fake'
Set-Content -Path (Join-Path $tmp 'src/lib/ollama/ggml-base.dll') -Value 'fake'
$fixture = Join-Path $tmp 'fixture.zip'
Compress-Archive -Path (Join-Path $tmp 'src/*') -DestinationPath $fixture
$goodSha = (Get-FileHash -Path $fixture -Algorithm SHA256).Hash.ToLowerInvariant()

$script:downloads = 0
function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction) $script:downloads++; $script:lastUri = $Uri; Copy-Item $fixture $OutFile }
$script:wingetCalls = 0
$script:wingetRc = 0
function winget { $script:wingetCalls++; $script:wingetVerb = $args[0]; $global:LASTEXITCODE = $script:wingetRc }
function ollama_installed_version { return $script:installed }

try {
    $env:_SHLIB_OLLAMA_ARCH = 'AMD64'
    $env:CI_DEFAULT_OLLAMA_VERSION = '0.40.0'
    $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 = $goodSha
    $env:LOCALAPPDATA = Join-Path $tmp 'appdata'

    $script:installed = $null
    check 'winget when it is there; nothing downloaded here' '0:1:0' "$(ollama_install):$($script:wingetCalls):$($script:downloads)"

    $script:wingetRc = 1
    $rc = ollama_install
    $dest = Join-Path $env:LOCALAPPDATA 'Programs/Ollama'
    check 'a failed winget falls back to the checked zip, per user' '0:True:True' "${rc}:$(Test-Path (Join-Path $dest 'ollama.exe')):$(Test-Path (Join-Path $dest 'lib/ollama/ggml-base.dll'))"
    check 'it asked for the pinned version' 'True' "$($script:lastUri -like '*/v0.40.0/ollama-windows-amd64.zip')"

    $p2 = Join-Path $tmp 'p2'
    check 'with -Prefix, winget is not used: the zip into that prefix' '0:True' "$(ollama_install -Prefix $p2):$(Test-Path (Join-Path $p2 'ollama.exe'))"

    # An upgrade: the old lib\ollama goes, nothing else in the directory does.
    $p8 = Join-Path $tmp 'p8'
    New-Item -ItemType Directory -Path (Join-Path $p8 'lib/ollama') -Force | Out-Null
    Set-Content -Path (Join-Path $p8 'lib/ollama/ggml-old.dll') -Value 'old'
    Set-Content -Path (Join-Path $p8 'app.exe') -Value 'other'
    check 'an upgrade removes the old libraries and keeps the rest' '0:False:True' "$(ollama_install -Prefix $p8):$(Test-Path (Join-Path $p8 'lib/ollama/ggml-old.dll')):$(Test-Path (Join-Path $p8 'app.exe'))"

    $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 = ('0' * 64)
    $p3 = Join-Path $tmp 'p3'
    check 'a zip that does not match is not unpacked' '1:False' "$(ollama_install -Prefix $p3):$(Test-Path (Join-Path $p3 'ollama.exe'))"
    $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 = ''
    check 'no pin: nothing downloaded' '3' "$(ollama_install -Prefix (Join-Path $tmp 'p4'))"
    $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 = $goodSha

    $env:_SHLIB_OLLAMA_ARCH = 'x86'
    check 'an architecture with no zip' '3' "$(ollama_install -Prefix (Join-Path $tmp 'p5'))"
    $env:_SHLIB_OLLAMA_ARCH = 'AMD64'

    $script:installed = '0.40.0'
    $before = $script:downloads
    check 'the pinned version installed: nothing to do' "0:$before" "$(ollama_install -Prefix (Join-Path $tmp 'p6')):$($script:downloads)"
    $script:installed = '0.30.2'
    check 'an older one is replaced' '0' "$(ollama_install -Prefix (Join-Path $tmp 'p7'))"
    $script:wingetRc = 0
    $rc = ollama_install
    check 'an older one with winget there: winget upgrade' '0:upgrade' "${rc}:$($script:wingetVerb)"
    check 'versions compare as numbers' 'True False' "$(_ollama_install_at_least '0.100.0' '0.40.0') $(_ollama_install_at_least '0.9.0' '0.40.0')"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { note "FAILED: $script:failures"; exit 1 }
note 'ALL PASSED'

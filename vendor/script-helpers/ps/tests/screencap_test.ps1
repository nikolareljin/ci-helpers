# Behaviour tests for ps/lib/screencap.ps1.
#
# A recording longer than screenrecord's cap is made in chunks, in a temp
# directory. A stop part-way (Ctrl-C ends the pipeline the same way a throw
# does) must remove that directory. adb and ffmpeg are stubs; no device.
#
# Usage: pwsh -NoProfile -File ps/tests/screencap_test.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'lib' 'screencap.ps1'))

$script:failures = 0
function note([string]$m)  { Write-Host "[screencap_test.ps1] $m" }
function fail([string]$m)  { Write-Host "[screencap_test.ps1][ERROR] $m"; $script:failures++ }

$script:stop = $false
function ffmpeg { $global:LASTEXITCODE = 0 }
function adb {
    if ($script:stop -and ($args -contains 'screenrecord')) { throw 'stopped' }
    $global:LASTEXITCODE = 0
}

# Its own temp root, so only this test's directories are counted.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("screencap-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$saved = @{ TMPDIR = $env:TMPDIR; TEMP = $env:TEMP; TMP = $env:TMP }
$env:TMPDIR = $root; $env:TEMP = $root; $env:TMP = $root
try {
    function left { return @(Get-ChildItem $root -Directory -Force) }
    $long = $script:ScreencapAndroidMaxSeconds + 10

    $script:stop = $false
    $ok = _Screencap_RecordAndroid -Serial x -Out (Join-Path $root 'out.mp4') -Seconds $long
    if ($ok -and (left).Count -eq 0) { note 'chunked recording: temp directory removed' }
    else { fail "chunked recording: ok=$ok, left $((left).Count) directory(ies)" }

    $script:stop = $true
    $threw = $false
    try { _Screencap_RecordAndroid -Serial x -Out (Join-Path $root 'out.mp4') -Seconds $long | Out-Null } catch { $threw = $true }
    if ($threw -and (left).Count -eq 0) { note 'stopped mid-recording: temp directory removed' }
    else { fail "stopped mid-recording: threw=$threw, left $((left).Count) directory(ies)" }
}
finally {
    $env:TMPDIR = $saved.TMPDIR; $env:TEMP = $saved.TEMP; $env:TMP = $saved.TMP
    Remove-Item -Recurse -Force $root
}

if ($script:failures -eq 0) { note 'ALL PASSED'; exit 0 }
note "$($script:failures) FAILURE(S)"
exit 1

# Behaviour tests for ps/lib/hosts.ps1.
#
# Both functions write the hosts file elevated. A newline in -Domain or -Ip
# wrote a second, unrelated entry, and -Ip took any string. The tests run
# against a temporary hosts file with is_admin stubbed, so nothing real is
# touched and no elevation is needed.
#
# Usage: pwsh -NoProfile -File ps/tests/hosts_test.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'lib' 'hosts.ps1'))

$script:failures = 0
function note([string]$m)  { Write-Host "[hosts_test.ps1] $m" }
function fail([string]$m)  { Write-Host "[hosts_test.ps1][ERROR] $m"; $script:failures++ }
function is_admin { return $true }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hosts-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$_SHLIB_HOSTS_FILE = Join-Path $tmp 'hosts'

function reset_hosts {
    Set-Content -Path $_SHLIB_HOSTS_FILE -Value @('# test hosts', "127.0.0.1`tlocalhost") -Encoding ascii
}
function hosts_lines { return @(Get-Content $_SHLIB_HOSTS_FILE) }

# expect_refused <label> <scriptblock>: the call must throw and leave the file unchanged.
function expect_refused([string]$label, [scriptblock]$call) {
    reset_hosts
    $before = (hosts_lines) -join "`n"
    $threw = $false
    try { & $call } catch { $threw = $true }
    $after = (hosts_lines) -join "`n"
    if (-not $threw)         { fail "$label was accepted" }
    elseif ($after -ne $before) { fail "$label threw but changed the hosts file: $after" }
    else                     { note "refuses $label" }
}

try {
    $nl = "`n"
    expect_refused 'a blank -Domain'              { add_hosts_entry -Domain '' }
    expect_refused 'a whitespace -Domain'         { add_hosts_entry -Domain '   ' }
    expect_refused 'a newline in -Domain'         { add_hosts_entry -Domain "demo.local${nl}10.9.9.9`tevil.example" }
    expect_refused 'a trailing newline in -Domain' { add_hosts_entry -Domain "demo.local$nl" }
    expect_refused 'a space in -Domain'           { add_hosts_entry -Domain 'demo.local other.example' }
    expect_refused 'a # in -Domain'               { add_hosts_entry -Domain 'demo#x' }
    expect_refused 'a newline in -Ip'             { add_hosts_entry -Domain 'demo.local' -Ip "127.0.0.1${nl}10.9.9.9`tevil.example" }
    expect_refused 'a trailing newline in -Ip'    { add_hosts_entry -Domain 'demo.local' -Ip "127.0.0.1$nl" }
    expect_refused 'a non-address -Ip'            { add_hosts_entry -Domain 'demo.local' -Ip 'not-an-ip' }
    expect_refused 'a hostname as -Ip'            { add_hosts_entry -Domain 'demo.local' -Ip 'example.com' }
    expect_refused 'a short-form IPv4 -Ip'        { add_hosts_entry -Domain 'demo.local' -Ip '127.1' }
    expect_refused 'an out-of-range IPv4 -Ip'     { add_hosts_entry -Domain 'demo.local' -Ip '300.1.1.1' }
    expect_refused 'a blank remove -Domain'       { remove_hosts_entry -Domain '' }
    expect_refused 'a newline in remove -Domain'  { remove_hosts_entry -Domain "localhost$nl" }

    # --- the normal path still works --------------------------------------
    reset_hosts
    add_hosts_entry -Domain 'demo.local' | Out-Null
    add_hosts_entry -Domain 'v6.local' -Ip '::1' | Out-Null
    add_hosts_entry -Domain 'lan_host.example' -Ip '192.0.2.10' | Out-Null
    add_hosts_entry -Domain 'demo.local' | Out-Null   # already present: no duplicate
    $lines = hosts_lines
    if (@($lines | Where-Object { $_ -eq "127.0.0.1`tdemo.local" }).Count -ne 1) { fail "demo.local not added exactly once: $($lines -join ' | ')" }
    elseif (-not ($lines -contains "::1`tv6.local"))                 { fail "IPv6 entry not added: $($lines -join ' | ')" }
    elseif (-not ($lines -contains "192.0.2.10`tlan_host.example"))  { fail "IPv4 entry with an underscore name not added: $($lines -join ' | ')" }
    elseif ($lines.Count -ne 5)                                      { fail "unexpected line count $($lines.Count): $($lines -join ' | ')" }
    else { note 'adds valid IPv4 and IPv6 entries once' }

    remove_hosts_entry -Domain 'demo.local' | Out-Null
    $lines = hosts_lines
    if ($lines -match 'demo\.local')           { fail "demo.local not removed: $($lines -join ' | ')" }
    elseif (-not ($lines -contains '# test hosts')) { fail 'remove dropped a comment line' }
    elseif (-not ($lines -contains "::1`tv6.local")) { fail 'remove dropped an unrelated entry' }
    else { note 'removes an entry and keeps comments and other entries' }
}
finally {
    Remove-Item -Recurse -Force $tmp
}

if ($script:failures -eq 0) { note 'ALL PASSED'; exit 0 }
note "$($script:failures) FAILURE(S)"
exit 1

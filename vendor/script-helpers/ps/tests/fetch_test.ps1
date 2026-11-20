# Behaviour tests for ps/lib/fetch.ps1.
#
# Invoke-WebRequest is a stub that writes a partial file and throws for the
# first $script:failFirst calls, then writes the asset. Nothing is fetched.
#
# Usage: pwsh -NoProfile -File ps/tests/fetch_test.ps1
$ErrorActionPreference = 'Stop'
$lib = Join-Path (Join-Path $PSScriptRoot '..') 'lib'
. (Join-Path $lib 'logging.ps1')
. (Join-Path $lib 'fetch.ps1')

$script:failures = 0
function note([string]$m) { Write-Host "[fetch_test.ps1] $m" }
function check([string]$label, $want, $got) {
    if ("$want" -ceq "$got") { note "  ok  $label" } else { Write-Host "[fetch_test.ps1][ERROR] ${label}: expected [$want], got [$got]"; $script:failures++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

$script:calls = 0
$script:failFirst = 0
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    $script:calls++
    if ($script:failFirst -lt 0 -or $script:calls -le $script:failFirst) {
        Set-Content -Path $OutFile -Value 'partial'
        throw 'Unable to connect to the remote server'
    }
    Set-Content -Path $OutFile -Value 'asset'
}

try {
    $out = Join-Path $tmp 'a.bin'

    $script:calls = 0; $script:failFirst = 2
    $rc = fetch_to_file -Label 't' -Url 'https://github.com/o/r/releases/download/v1/a' -OutFile $out -DelaySeconds 0
    check 'two failures, then the file on the third attempt' '0:3:asset' "${rc}:$($script:calls):$((Get-Content $out -Raw).Trim())"

    Remove-Item $out -Force
    $script:calls = 0; $script:failFirst = -1
    $rc = fetch_to_file -Label 't' -Url 'https://github.com/o/r/releases/download/v1/a' -OutFile $out -DelaySeconds 0 2>$null
    check 'every attempt fails: 1, three attempts, no partial file left' '1:3:False' "${rc}:$($script:calls):$(Test-Path $out)"

    # An exception text over several lines is printed as one line, so it cannot forge a log line.
    $script:logged = @()
    function log_error([string]$m) { $script:logged += $m }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction) throw "boom`n[ERROR] forged" }
    $rc = fetch_to_file -Label 't' -Url 'https://github.com/o/r' -OutFile $out -DelaySeconds 0
    check 'a multi-line error is logged as one line' '1:1:False' "${rc}:$($script:logged.Count):$($script:logged[0].Contains("`n"))"
    # An HTTP 404 is not retried; a 503 and a 429 are.
    foreach ($row in @(@(404, '1:1'), @(503, '1:3'), @(429, '1:3'))) {
        $script:calls = 0; $script:status = $row[0]
        function Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
            $script:calls++
            $e = New-Object System.Exception "HTTP $($script:status)"
            Add-Member -InputObject $e -MemberType NoteProperty -Name Response -Value ([pscustomobject]@{ StatusCode = $script:status })
            throw $e
        }
        $rc = fetch_to_file -Label 't' -Url 'https://h.example/a' -OutFile $out -DelaySeconds 0
        check "HTTP $($row[0]): attempts" $row[1] "${rc}:$($script:calls)"
    }
    # A query can carry a token: neither it nor the exception text (which can quote it) is logged.
    $script:logged = @()
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction) throw "404 for $Uri" }
    $rc = fetch_to_file -Label 't' -Url 'https://h.example/a?sig=s3cr3t' -OutFile $out -Attempts 1 -DelaySeconds 0
    check 'a query is not logged, nor the error text' '1:False:True' "${rc}:$($script:logged[0].Contains('s3cr3t')):$($script:logged[0].EndsWith('URL https://h.example/a?(not shown)'))"
    Remove-Item function:log_error
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
        $script:calls++
        if ($script:failFirst -lt 0 -or $script:calls -le $script:failFirst) {
            Set-Content -Path $OutFile -Value 'partial'
            throw 'Unable to connect to the remote server'
        }
        Set-Content -Path $OutFile -Value 'asset'
    }

    check 'an empty URL is refused' '2' "$(fetch_to_file -Label 't' -Url '' -OutFile $out 2>$null)"
    check 'an empty label is refused' '2' "$(fetch_to_file -Label '' -Url 'https://h.example/a' -OutFile $out 2>$null)"
    check 'the host of a URL' 'github.com' (fetch_url_host 'https://github.com/o/r')
    check 'an unparseable URL has no host printed' '(unknown host)' (fetch_url_host 'not a url@secret')
    foreach ($u in @('ftp://u@host.example/x', "https://b$([char]0x202E)ad.example/a", "https://b$([char]0xFC)cher.example/a", "https://h.example$([char]0xA0)x/a")) {
        check "no host printed for $(($u -replace '[^\x21-\x7E]', '?'))" '(unknown host)' (fetch_url_host $u)
    }
    check 'the host of a URL with a non-ASCII path' 'h.example' (fetch_url_host "https://h.example/b$([char]0xFC)")
    $n = '(URL not shown)'
    foreach ($row in @(
        @('https://user:pass@example.com/a', $n),
        @('https://token@example.com/a', $n),
        @('HTTPS://tok@Example.com', $n),
        @('user:pass@example.com/a', $n),
        @('ht!tp://x@y', $n),
        @('ftp://example.com/a', $n),
        @('https://', $n),
        @("https://example.com/a`n[ERROR] forged", $n),
        @('https://example.com/a b', $n),
        @('https://example.com/a@b', 'https://example.com/a@b'),
        @('https://example.com/a?u=x@y', 'https://example.com/a?(not shown)'),
        @('https://github.com/o/r', 'https://github.com/o/r'))) {
        check "display of $(($row[0] -replace '[^\x21-\x7E]', '?'))" $row[1] (fetch_url_display $row[0])
    }
    # Shared with tests/fetch_test.sh: both sides print the same host and URL.
    foreach ($line in Get-Content (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'tests/fixtures/fetch_url_cases.txt')) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line.Split('|')
        $u = $f[0].Replace('\\', [string][char]0).Replace('\t', "`t").Replace('\n', "`n").Replace('\u00ad', [string][char]0xAD).Replace([string][char]0, '\')
        $d = if ($f[2] -eq '=') { $u } else { $f[2] }
        check "shared case $($f[0])" "$($f[1])|$d" "$(fetch_url_host $u)|$(fetch_url_display $u)"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { note "$($script:failures) failure(s)"; exit 1 }
note 'all passed'

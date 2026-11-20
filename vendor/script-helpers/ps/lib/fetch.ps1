# fetch: download one release asset to a file, with retries and a clear error.
# PowerShell companion to lib/fetch.sh.
#
# Invoke-WebRequest has no retry option in Windows PowerShell 5.1, so the
# retry is a loop here: 3 attempts, 2 seconds apart. A failed download deletes
# the output file, so a partial file is never left for the caller to check or
# unpack. Callers still verify the checksum.
#
# Redirects: PowerShell 7 (.NET) does not follow an https URL to http.
# Windows PowerShell 5.1 does; the checksum each caller runs on the file is
# what protects the download there.
#
# Requires: logging (log_error; plain error stream without it)

# Usage: fetch_url_host -Url <url>
# Returns: the host of an http or https URL, without user info or port, else
#   '(unknown host)'. Fails closed: another or no scheme, an authority (from
#   '://' to the first '/', '?' or '#') with anything but printable ASCII or
#   with a backslash, an empty host or an unclosed '['. Same rule as
#   lib/fetch.sh; tests/fixtures/fetch_url_cases.txt holds both. Plain string
#   rules, not [uri]: [uri] lowercases the host and reads 'a\@b' as host 'a'.
# Output: none.
function fetch_url_host {
    param([string]$Url)
    $unknown = '(unknown host)'
    # Ordinal: a culture compare skips a soft hyphen, so 'https<U+00AD>' -eq 'https'.
    $i = if ($Url) { $Url.IndexOf('://', [StringComparison]::Ordinal) } else { -1 }
    if ($i -lt 1) { return $unknown }
    $scheme = $Url.Substring(0, $i).ToLowerInvariant()
    if (-not ([string]::Equals($scheme, 'http', [StringComparison]::Ordinal) -or [string]::Equals($scheme, 'https', [StringComparison]::Ordinal))) { return $unknown }
    $rest = $Url.Substring($i + 3)
    $j = $rest.IndexOfAny([char[]]@('/', '?', '#'))
    $h = if ($j -ge 0) { $rest.Substring(0, $j) } else { $rest }
    if ($h -cmatch '[^\x21-\x7E]' -or $h.Contains('\')) { return $unknown }
    $h = $h.Substring($h.LastIndexOf('@') + 1)
    if ($h.StartsWith('[')) {
        $k = $h.IndexOf(']')
        $h = if ($k -gt 1) { $h.Substring(0, $k + 1) } else { '' }
    } else {
        $k = $h.IndexOf(':')
        if ($k -ge 0) { $h = $h.Substring(0, $k) }
    }
    if (-not $h) { return $unknown }
    return $h
}

# Usage: fetch_url_display -Url <url>
# Returns: scheme, authority and path, with a query shown as '?(not shown)' and
#   a fragment left out, when the URL is printable ASCII with no space,
#   fetch_url_host names its host and its authority has no '@'; else
#   '(URL not shown)'. Fails closed: user info, a query or fragment (a signed
#   URL carries its token there), another or no scheme, a character that could
#   forge a log line, or a URL that does not parse is never shown. Same rule
#   as lib/fetch.sh.
# Output: none.
function fetch_url_display {
    param([string]$Url)
    $hidden = '(URL not shown)'
    if (-not $Url -or $Url -cmatch '[^\x21-\x7E]') { return $hidden }
    if ((fetch_url_host $Url) -ceq '(unknown host)') { return $hidden }
    $s = $Url.IndexOf('://', [StringComparison]::Ordinal) + 3
    $rest = $Url.Substring($s)
    $j = $rest.IndexOfAny([char[]]@('/', '?', '#'))
    $auth = if ($j -ge 0) { $rest.Substring(0, $j) } else { $rest }
    if ($auth.Contains('@')) { return $hidden }
    $pre = $rest.Substring($auth.Length)
    $k = $pre.IndexOf('#')
    if ($k -ge 0) { $pre = $pre.Substring(0, $k) }
    $q = $pre.IndexOf('?')
    if ($q -ge 0) { $pre = $pre.Substring(0, $q) + '?(not shown)' }
    return $Url.Substring(0, $s) + $auth + $pre
}

# Usage: fetch_to_file -Label <name> -Url <url> -OutFile <path> [-Attempts 3] [-DelaySeconds 2]
# Downloads <url> to <path>, retrying any error but an HTTP 4xx other than 408
# and 429. On failure the file is deleted
# and one error line names the label, the host, the attempts and the last error.
# Returns: 0 downloaded; 1 every attempt failed; 2 an empty label, URL or path.
# Output: error line on failure (log_error when logging is loaded).
function fetch_to_file {
    param(
        [string]$Label,
        [string]$Url,
        [string]$OutFile,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 2
    )
    if (-not $Label -or -not $Url -or -not $OutFile) {
        _fetch_err 'fetch_to_file: usage: fetch_to_file -Label <name> -Url <url> -OutFile <path>'
        return 2
    }
    if ($Attempts -lt 1) { $Attempts = 1 }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 does not negotiate TLS 1.2 by default.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $last = ''
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes this ~10x slower
    try {
        for ($i = 1; $i -le $Attempts; $i++) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
                return 0
            } catch {
                # One line: a newline in the text could forge a log line.
                $last = ($_.Exception.Message -replace '[\x00-\x1F\x7F]+', ' ').Trim()
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                # A 4xx other than 408 or 429 will not change on a retry; curl --retry stops there too.
                $code = 0
                try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
                if ($code -ge 400 -and $code -lt 500 -and $code -ne 408 -and $code -ne 429) { $Attempts = $i; break }
                if ($i -lt $Attempts -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
            }
        }
    } finally { $ProgressPreference = $prev }
    $shown = fetch_url_display $Url
    # The exception text can quote the URL; unless all of it is shown, the text is hidden.
    if ($shown -cne $Url) { $last = '(error text not shown with the URL)' }
    _fetch_err "${Label}: download failed from $(fetch_url_host $Url) after $Attempts $(if ($Attempts -eq 1) { 'attempt' } else { 'attempts' }): $last; URL $shown"
    return 1
}

function _fetch_err([string]$m) {
    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error $m } else { [Console]::Error.WriteLine("[ERROR] $m") }
}

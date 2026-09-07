# Static-site preview server — PowerShell companion to lib/serve.sh.
#
# Serves a directory over HTTP for local preview of a static / GitHub-Pages
# build. Prefers python3, then python, then `npx http-server`. Blocks until
# Ctrl-C. Function name mirrors the Bash module so the docs are shared.
#
# Requires: logging

# Returns $true when something is already listening on the port.
function _Shlib_Serve_PortBusy {
    param([int]$Port)
    # Get-NetTCPConnection is Windows-only; TcpClient works everywhere PS runs.
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        # A connect that completes fast means something answered => port is busy.
        if ($iar.AsyncWaitHandle.WaitOne(200)) {
            try { $client.EndConnect($iar); return $true } catch { return $false }
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Returns $true when `python` is Python 3 (the stdlib server module differs).
function _Shlib_Serve_PythonIsV3 {
    param([string]$Exe)
    & $Exe -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>$null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
Serve a directory over HTTP for local preview.

.DESCRIPTION
Serves <Directory> on the first free port at or after <Port> (default 8000),
scanning up to 20 ports ahead. Prefers python3, then python (3 or 2), then
`npx http-server`. Blocks until Ctrl-C.

Returns 2 for bad arguments, 3 when no server tool is available, and 4 when no
free port was found in the probed range.

.EXAMPLE
serve_static_site ./_site

.EXAMPLE
serve_static_site ./public 4000
#>
function serve_static_site {
    param(
        [Parameter(Position = 0)][string]$Directory,
        [Parameter(Position = 1)]$Port = 8000
    )

    if (-not $Directory -or -not (Test-Path -Path $Directory -PathType Container)) {
        log_error "serve_static_site: directory not found: '$Directory'"
        return 2
    }

    # Reject non-numeric ports early: the free-port probe does arithmetic on
    # this value, which would fail noisily on e.g. "abc".
    $portNum = 0
    if (-not [int]::TryParse([string]$Port, [ref]$portNum) -or $portNum -lt 1 -or $portNum -gt 65535) {
        log_error "serve_static_site: invalid port: '$Port' (expected 1-65535)"
        return 2
    }

    $p = $portNum
    $tries = 0
    $found = $false
    while ($tries -lt 20 -and $p -le 65535) {
        if (-not (_Shlib_Serve_PortBusy -Port $p)) { $found = $true; break }
        $p++; $tries++
    }
    if (-not $found) {
        log_error "serve_static_site: no free port found in $portNum..$($p - 1)"
        return 4
    }

    $full = (Resolve-Path $Directory).Path
    log_info "Serving '$full' at http://localhost:$p/  (Ctrl-C to stop)"

    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        & python3 -m http.server $p --directory $full
        return $LASTEXITCODE
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        Push-Location $full
        try {
            if (_Shlib_Serve_PythonIsV3 'python') {
                & python -m http.server $p
            } else {
                & python -m SimpleHTTPServer $p
            }
            return $LASTEXITCODE
        } finally { Pop-Location }
    }
    if (Get-Command npx -ErrorAction SilentlyContinue) {
        & npx --yes http-server $full -p $p
        return $LASTEXITCODE
    }

    log_error "serve_static_site: need python3, python, or npx to serve"
    return 3
}

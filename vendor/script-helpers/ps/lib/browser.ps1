# Browser/URL helpers - PowerShell companion to lib/browser.sh.

# Usage: open_url -Url <url>
# Opens the URL with the default handler (Start-Process).
# Returns: nothing.
# Output: none; error stream when no handler is registered.
function open_url {
    param([string]$Url)
    Start-Process $Url
}

# Usage: check_port_open [-HostName <host>] -Port <n> [-TimeoutMs <ms>]   (defaults: localhost, 1000)
# -Host is accepted as an alias of -HostName.
# Returns: $true when a TCP connect succeeds within the timeout, else $false.
# Output: none.
function check_port_open {
    # -HostName, not -Host: $Host is a read-only automatic variable and binding
    # a parameter of that name threw. -Host still works through the alias.
    param([Alias('Host')][string]$HostName = 'localhost', [int]$Port, [int]$TimeoutMs = 1000)
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $conn = $tcp.BeginConnect($HostName, $Port, $null, $null)
        $ok   = $conn.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $tcp.EndConnect($conn) }  # throws on refused/error; WaitOne alone doesn't
        return $ok
    } catch {
        return $false
    } finally {
        $tcp.Close()
    }
}

# Usage: wait_for_port -Port <n> [-HostName <host>] [-TimeoutSec <s>] [-IntervalSec <s>]   (defaults: localhost, 60, 2)
# Returns: $true as soon as the port accepts a connection, $false on timeout.
# Output: stderr [ERROR] on timeout.
function wait_for_port {
    param(
        [int]$Port,
        [Alias('Host')][string]$HostName = 'localhost',
        [int]$TimeoutSec = 60,
        [int]$IntervalSec = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (check_port_open -HostName $HostName -Port $Port) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Port $Port not open after ${TimeoutSec}s" }
    return $false
}

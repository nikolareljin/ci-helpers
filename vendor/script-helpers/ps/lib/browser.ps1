# Browser/URL helpers — PowerShell companion to lib/browser.sh.

function open_url {
    param([string]$Url)
    Start-Process $Url
}

function check_port_open {
    param([string]$Host = 'localhost', [int]$Port, [int]$TimeoutMs = 1000)
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $conn = $tcp.BeginConnect($Host, $Port, $null, $null)
        $ok   = $conn.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $tcp.EndConnect($conn) }  # throws on refused/error; WaitOne alone doesn't
        return $ok
    } catch {
        return $false
    } finally {
        $tcp.Close()
    }
}

function wait_for_port {
    param(
        [int]$Port,
        [string]$Host = 'localhost',
        [int]$TimeoutSec = 60,
        [int]$IntervalSec = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (check_port_open -Host $Host -Port $Port) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Port $Port not open after ${TimeoutSec}s" }
    return $false
}

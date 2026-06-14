# Port detection helpers — PowerShell companion to lib/ports.sh.
# Uses Get-NetTCPConnection (available on Windows 8+/Server 2012+).

function port_in_use {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn)
}

function list_port_usage_details {
    param([int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) { return }
    foreach ($c in $conns) {
        $pid  = $c.OwningProcess
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        $name = if ($proc) { $proc.ProcessName } else { 'unknown' }
        Write-Output "$name (PID $pid)"
    }
}

function list_port_listener_pids {
    param([int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) { return }
    $conns.OwningProcess | Sort-Object -Unique | Write-Output
}

function get_port_conflicts_json {
    param([int[]]$Ports)
    $conflicts = @()
    foreach ($port in $Ports) {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            foreach ($c in $conns) {
                $pid  = $c.OwningProcess
                $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
                $conflicts += [PSCustomObject]@{
                    port    = $port
                    pid     = $pid
                    process = if ($proc) { $proc.ProcessName } else { 'unknown' }
                }
            }
        }
    }
    if ($conflicts.Count -eq 0) { return '[]' }
    # Wrap in @() to force array output from ConvertTo-Json even for a single element;
    # without this PS unwraps a one-item array to a bare object, breaking JSON consumers.
    return (@($conflicts) | ConvertTo-Json -Compress)
}

# Hosts file helpers — PowerShell companion to lib/hosts.sh.
# Windows hosts file: C:\Windows\System32\drivers\etc\hosts
# Admin elevation is required to modify it.

$_SHLIB_HOSTS_FILE = "$env:SystemRoot\System32\drivers\etc\hosts"

function add_hosts_entry {
    param([string]$Domain, [string]$Ip = '127.0.0.1')
    if (-not (Get-Command is_admin -ErrorAction SilentlyContinue) -or -not (is_admin)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Admin elevation required to modify hosts file." }
        throw "Admin elevation required"
    }
    $entry   = "$Ip`t$Domain"
    $escaped = [regex]::Escape($Domain)
    $active  = Get-Content $_SHLIB_HOSTS_FILE | Where-Object { $_ -notmatch '^\s*#' }
    if ($active -match "(?i)(^|\s)${escaped}(\s|$)") {
        if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "Host entry for $Domain already exists." }
        return
    }
    Add-Content -Path $_SHLIB_HOSTS_FILE -Value $entry -Encoding ascii
    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Added hosts entry: $entry" }
}

function remove_hosts_entry {
    param([string]$Domain)
    if (-not (Get-Command is_admin -ErrorAction SilentlyContinue) -or -not (is_admin)) {
        throw "Admin elevation required"
    }
    $escaped  = [regex]::Escape($Domain)
    $lines    = Get-Content $_SHLIB_HOSTS_FILE
    # Only remove active (non-comment) lines that match the domain; leave comments intact.
    $filtered = $lines | Where-Object {
        ($_ -match '^\s*#') -or ($_ -notmatch "(?i)(^|\s)${escaped}(\s|$)")
    }
    Set-Content -Path $_SHLIB_HOSTS_FILE -Value $filtered -Encoding ascii
    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Removed hosts entry for $Domain" }
}

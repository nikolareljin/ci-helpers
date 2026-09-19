# Hosts file helpers — PowerShell companion to lib/hosts.sh.
# Windows hosts file: C:\Windows\System32\drivers\etc\hosts
# Admin elevation is required to modify it.

$_SHLIB_HOSTS_FILE = "$env:SystemRoot\System32\drivers\etc\hosts"

# Both parameters are written into the hosts file, elevated. A newline in
# either wrote a second, unrelated entry -- any name pointed at any address --
# so a domain is limited to hostname characters (the rule lib/hosts.sh uses)
# and an address must parse as one. \A and \z rather than ^ and $: .NET's $
# also matches before a trailing newline. The ValidateScript blocks throw their
# own message because Windows PowerShell 5.1 has no ErrorMessage= on the
# attribute.

function add_hosts_entry {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            if ($_ -cmatch '\A[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9_])?\z') { return $true }
            throw "'$_' is not a valid hostname (letters, digits, '.', '-', '_')."
        })]
        [string]$Domain,
        [ValidateScript({
            $parsed = $null
            $ok = [System.Net.IPAddress]::TryParse($_, [ref]$parsed) -and (
                ($_ -cmatch '\A[0-9]{1,3}(\.[0-9]{1,3}){3}\z') -or
                ($_ -cmatch '\A[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*\z'))
            if ($ok) { return $true }
            throw "'$_' is not an IPv4 or IPv6 address."
        })]
        [string]$Ip = '127.0.0.1'
    )
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
    # Mandatory and non-blank: an empty domain makes the pattern below
    # "(^|\s)(\s|$)", which matches every aligned hosts line, and this runs
    # elevated.
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            if ($_ -cmatch '\A[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9_])?\z') { return $true }
            throw "'$_' is not a valid hostname (letters, digits, '.', '-', '_')."
        })]
        [string]$Domain
    )
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

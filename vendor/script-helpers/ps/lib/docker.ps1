# Docker/Docker Compose helpers - PowerShell companion to lib/docker.sh.

# Usage: get_docker_compose_cmd
# Returns: 'docker compose' or 'docker-compose'.
# Output: stderr [ERROR] and throws when docker or compose is missing.
function get_docker_compose_cmd {
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
        throw "Docker CLI not found. Install Docker Desktop and ensure it is on PATH."
    }
    docker compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'docker compose' }
    if (Get-Command 'docker-compose' -ErrorAction SilentlyContinue) { return 'docker-compose' }
    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Neither 'docker compose' nor 'docker-compose' found." }
    throw "Docker Compose not available"
}

# Usage: docker_compose <compose args...>
# Returns: compose's output lines; $LASTEXITCODE is compose's exit code.
# Output: stderr [DEBUG] the command line; throws as get_docker_compose_cmd.
function docker_compose {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    $cmd   = get_docker_compose_cmd
    if (Get-Command log_debug -ErrorAction SilentlyContinue) { log_debug "Executing: $cmd $($Args -join ' ')" }
    $parts = $cmd -split ' '
    if ($parts.Count -gt 1) {
        & $parts[0] @($parts[1..($parts.Count - 1)] + $Args)
    } else {
        & $parts[0] @Args
    }
}

# Usage: run_docker_compose <compose args...>
# Same as docker_compose.
# Returns: as docker_compose.
# Output: as docker_compose.
function run_docker_compose        { param([Parameter(ValueFromRemainingArguments)][string[]]$A); docker_compose @A }
# Usage: run_docker_compose_command <compose args...>
# Same as docker_compose.
# Returns: as docker_compose.
# Output: as docker_compose.
function run_docker_compose_command { param([Parameter(ValueFromRemainingArguments)][string[]]$A); docker_compose @A }

# Usage: check_docker
# Returns: $true when the CLI exists and `docker info` succeeds, else $false.
# Output: stderr [ERROR] with the reason on failure.
function check_docker {
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Docker CLI not found. Install Docker Desktop and ensure it is on PATH." }
        return $false
    }
    $info = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = ($info | ForEach-Object { "$_" }) -join ' '
        if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Docker daemon unavailable: $msg" }
        return $false
    }
    return $true
}

# Usage: service_is_running -ServiceName <name> [-ComposeFile <file>]
# Returns: $true when compose lists the service as running, else $false.
# Output: none; throws as get_docker_compose_cmd.
function service_is_running {
    param([string]$ServiceName, [string]$ComposeFile = '')
    $args = @('ps', '--services', '--filter', 'status=running')
    if ($ComposeFile) { $args = @('-f', $ComposeFile) + $args }
    $running = docker_compose @args 2>$null
    return ($running -split '\r?\n') -contains $ServiceName
}

# Usage: wait_for_service -ServiceName <name> [-TimeoutSec <s>] [-ComposeFile <file>]   (default 60)
# Returns: $true once running, $false on timeout.
# Output: stderr [ERROR] on timeout.
function wait_for_service {
    param([string]$ServiceName, [int]$TimeoutSec = 60, [string]$ComposeFile = '')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (service_is_running $ServiceName $ComposeFile) { return $true }
        Start-Sleep -Seconds 2
    }
    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error "Service '$ServiceName' did not become running within ${TimeoutSec}s" }
    return $false
}

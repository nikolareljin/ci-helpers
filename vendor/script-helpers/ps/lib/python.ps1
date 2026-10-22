# Python helpers - PowerShell companion to lib/python.sh.

# Usage: python_version -Bin <python|python3|py>
# Returns: "MAJOR.MINOR" of the interpreter; $null when it cannot run.
# Output: none.
function python_version {
    param([string]$Bin)
    try {
        $pyArgs = @('-c', 'import sys; v=sys.version_info; print("{}.{}".format(v[0],v[1]))')
        if ($Bin -eq 'py') { $pyArgs = @('-3') + $pyArgs }
        $out = & $Bin @pyArgs 2>&1
        if ($LASTEXITCODE -eq 0) { return $out.Trim() }
    } catch {}
    return $null
}

# Usage: python_has_min_version -Bin <exe> [-MinMajor <n>] [-MinMinor <n>]   (default 3.8)
# Returns: $true when the interpreter is at least MinMajor.MinMinor, else $false.
# Output: none.
function python_has_min_version {
    param([string]$Bin, [int]$MinMajor = 3, [int]$MinMinor = 8)
    $ver = python_version $Bin
    if (-not $ver) { return $false }
    if ($ver -notmatch '^(\d+)\.(\d+)$') { return $false }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]
    return ($maj -gt $MinMajor) -or ($maj -eq $MinMajor -and $min -ge $MinMinor)
}

# Usage: python_can_run -Bin <exe>
# Returns: $true when Bin resolves as a command, else $false.
# Output: none.
function python_can_run {
    param([string]$Bin)
    if (-not $Bin) { return $false }
    return ($null -ne (Get-Command $Bin -ErrorAction SilentlyContinue))
}

# Usage: python_pick_3 [-MinMajor <n>] [-MinMinor <n>]
# Returns: the first of py, python, python3 that meets the minimum; $null when none.
# Output: none.
function python_pick_3 {
    param([int]$MinMajor = 3, [int]$MinMinor = 8)
    # On Windows: py launcher, python, python3
    foreach ($candidate in @('py', 'python', 'python3')) {
        if (python_can_run $candidate) {
            # py launcher needs -3 flag
            $bin = if ($candidate -eq 'py') { 'py' } else { $candidate }
            if (python_has_min_version $bin $MinMajor $MinMinor) { return $bin }
        }
    }
    return $null
}

# Usage: python_resolve_3 [-Requested <exe>] [-MinMajor <n>] [-MinMinor <n>]
# Returns: Requested when it meets the minimum, else python_pick_3's result.
# Output: none.
function python_resolve_3 {
    param([string]$Requested = '', [int]$MinMajor = 3, [int]$MinMinor = 8)
    if ($Requested -and (python_can_run $Requested) -and (python_has_min_version $Requested $MinMajor $MinMinor)) {
        return $Requested
    }
    return python_pick_3 $MinMajor $MinMinor
}

# Usage: python_ensure_venv -PythonBin <exe> -VenvDir <dir>
# Creates the venv when VenvDir\Scripts\python.exe is missing.
# Returns: the venv's python.exe path.
# Output: host the venv tool's output; throws on missing arguments or when creation fails.
function python_ensure_venv {
    param([string]$PythonBin, [string]$VenvDir)
    if (-not $PythonBin -or -not $VenvDir) { throw "python_ensure_venv: PythonBin and VenvDir required" }

    $venvPython = Join-Path $VenvDir 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        $venvArgs = if ($PythonBin -eq 'py') { @('-3', '-m', 'venv', $VenvDir) } else { @('-m', 'venv', $VenvDir) }
        & $PythonBin @venvArgs | Out-Host
        if ($LASTEXITCODE -ne 0) {
            if (Get-Command print_error -ErrorAction SilentlyContinue) { print_error "Failed to create virtualenv at $VenvDir" }
            throw "Failed to create venv"
        }
    }
    return $venvPython
}

# Usage: activate_venv -VenvDir <dir>
# Runs VenvDir\Scripts\Activate.ps1 inside this function. Its environment variables
# (PATH, VIRTUAL_ENV) reach the caller; its prompt function does not. To get the
# prompt too, dot-source Activate.ps1 from the caller's own scope.
# Returns: nothing.
# Output: none; throws when the activate script is missing.
function activate_venv {
    param([string]$VenvDir)
    $activate = Join-Path $VenvDir 'Scripts\Activate.ps1'
    if (Test-Path $activate) { . $activate }
    else { throw "Venv activate script not found: $activate" }
}

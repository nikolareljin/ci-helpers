# Python helpers — PowerShell companion to lib/python.sh.

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

function python_has_min_version {
    param([string]$Bin, [int]$MinMajor = 3, [int]$MinMinor = 8)
    $ver = python_version $Bin
    if (-not $ver) { return $false }
    if ($ver -notmatch '^(\d+)\.(\d+)$') { return $false }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]
    return ($maj -gt $MinMajor) -or ($maj -eq $MinMajor -and $min -ge $MinMinor)
}

function python_can_run {
    param([string]$Bin)
    if (-not $Bin) { return $false }
    return ($null -ne (Get-Command $Bin -ErrorAction SilentlyContinue))
}

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

function python_resolve_3 {
    param([string]$Requested = '', [int]$MinMajor = 3, [int]$MinMinor = 8)
    if ($Requested -and (python_can_run $Requested) -and (python_has_min_version $Requested $MinMajor $MinMinor)) {
        return $Requested
    }
    return python_pick_3 $MinMajor $MinMinor
}

function python_ensure_venv {
    param([string]$PythonBin, [string]$VenvDir)
    if (-not $PythonBin -or -not $VenvDir) { throw "python_ensure_venv: PythonBin and VenvDir required" }

    $venvPython = Join-Path $VenvDir 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        $venvArgs = if ($PythonBin -eq 'py') { @('-3', '-m', 'venv', $VenvDir) } else { @('-m', 'venv', $VenvDir) }
        & $PythonBin @venvArgs
        if ($LASTEXITCODE -ne 0) {
            if (Get-Command print_error -ErrorAction SilentlyContinue) { print_error "Failed to create virtualenv at $VenvDir" }
            throw "Failed to create venv"
        }
    }
    return $venvPython
}

function activate_venv {
    param([string]$VenvDir)
    $activate = Join-Path $VenvDir 'Scripts\Activate.ps1'
    if (Test-Path $activate) { . $activate }
    else { throw "Venv activate script not found: $activate" }
}

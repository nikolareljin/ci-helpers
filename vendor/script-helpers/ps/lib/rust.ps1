# Rust toolchain resolution for native PowerShell gates.
#
# CI installs rustup's stable toolchain. A Windows machine can also have a
# distribution Cargo earlier on PATH, so a gate must resolve Cargo through
# rustup instead of trusting the first command PATH offers.

# Usage: rust_toolchain_ci_uses [-Toolchain <toolchain>]
#
# Put the named rustup toolchain's Cargo directory first on PATH. The selected
# toolchain defaults to RUST_TOOLCHAIN, then stable. Returns $true on success;
# throws with the next action when rustup cannot provide a usable Cargo.
function rust_toolchain_ci_uses {
    param([string]$Toolchain = '')

    if (-not $Toolchain) {
        $Toolchain = if ($env:RUST_TOOLCHAIN) { $env:RUST_TOOLCHAIN } else { 'stable' }
    }

    if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
        throw "[rust] rustup is not installed; CI compiles with rustup's $Toolchain. Install it from https://rustup.rs, then run: rustup toolchain install $Toolchain"
    }

    # A rustup notice on stderr must not cost the path on stdout: Windows
    # PowerShell 5.1 turns redirected native stderr into errors, and a caller's
    # Stop preference makes them terminating. Success is the exit code.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $rustupCargo = ''
    $global:LASTEXITCODE = 0
    try {
        $out = @(& rustup which --toolchain $Toolchain cargo 2>$null) | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $null -ne $out) { $rustupCargo = "$out".Trim() }
    } catch {
        $rustupCargo = ''
    }
    if (-not $rustupCargo -or -not (Test-Path -LiteralPath $rustupCargo -PathType Leaf)) {
        throw "[rust] rustup has no usable cargo for '$Toolchain'. Run: rustup toolchain install $Toolchain"
    }

    $onPath = Get-Command cargo -ErrorAction SilentlyContinue
    $onPathSource = if ($onPath) {
        if ($onPath.Path) { $onPath.Path } else { $onPath.Source }
    } else { '' }
    if ($onPathSource -ne $rustupCargo) {
        $rustupVersion = try { (& $rustupCargo --version 2>$null | Select-Object -First 1) } catch { "a cargo that will not run, at $rustupCargo" }
        if (-not $rustupVersion) { $rustupVersion = "a cargo that will not run, at $rustupCargo" }
        Write-Warning "[rust] using $rustupVersion from rustup ($Toolchain)"
        if ($onPathSource) {
            $onPathVersion = try { (& $onPathSource --version 2>$null | Select-Object -First 1) } catch { 'an unusable cargo' }
            if (-not $onPathVersion) { $onPathVersion = 'an unusable cargo' }
            Write-Warning "[rust] PATH offered $onPathVersion, which is not what CI compiles with"
        }
    }

    $cargoDir = Split-Path -Parent $rustupCargo
    $separator = [System.IO.Path]::PathSeparator
    $segments = @($env:PATH -split [regex]::Escape([string]$separator) | Where-Object { $_ -and $_ -ne $cargoDir })
    $env:PATH = (@($cargoDir) + $segments) -join $separator
    return $true
}

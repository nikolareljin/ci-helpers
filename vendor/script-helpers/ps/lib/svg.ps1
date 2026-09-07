# SVG rasterization helpers — PowerShell companion to lib/svg.sh.
#
# Convert vector art (logos, icons) to PNG for app assets / launcher icons.
# Prefers Inkscape (best fidelity), falls back to ImageMagick (`magick`, then
# `convert`). Function names mirror the Bash module so the docs are shared.
#
# Note on Windows: ImageMagick's legacy `convert` collides with the built-in
# `convert.exe` (the FAT-to-NTFS conversion tool), which is why `magick` is
# preferred and the legacy name is only reached when it resolves to something
# that is not the system utility.
#
# Requires: logging

<#
.SYNOPSIS
Print the available SVG rasterizer.

.DESCRIPTION
Returns 'inkscape', 'magick' or 'convert', or $null when none is installed.
#>
function svg_rasterizer {
    if (Get-Command inkscape -ErrorAction SilentlyContinue) { return 'inkscape' }
    if (Get-Command magick   -ErrorAction SilentlyContinue) { return 'magick' }

    $conv = Get-Command convert -ErrorAction SilentlyContinue
    if ($conv) {
        # On Windows, `convert` is a Microsoft filesystem utility unless
        # ImageMagick shadowed it. Only accept it when it is not in the
        # Windows system directory.
        $sysDir = [System.Environment]::GetFolderPath('System')
        if ((get_os) -ne 'windows' -or -not $conv.Source -or -not $conv.Source.StartsWith($sysDir, 'OrdinalIgnoreCase')) {
            return 'convert'
        }
    }
    return $null
}

<#
.SYNOPSIS
Render an SVG to a square PNG.

.DESCRIPTION
Renders <InputSvg> to <OutputPng> at <Size>x<Size> pixels (default 1024).
Returns 2 for bad arguments, 3 when no rasterizer is available, 1 when the
render itself fails, and 0 on success.

.EXAMPLE
svg_rasterize logo.svg logo.png 512
#>
function svg_rasterize {
    param(
        [Parameter(Position = 0)][string]$InputSvg,
        [Parameter(Position = 1)][string]$OutputPng,
        [Parameter(Position = 2)]$Size = 1024
    )

    if (-not $InputSvg -or -not $OutputPng) {
        log_error "usage: svg_rasterize <in.svg> <out.png> [size]"
        return 2
    }
    $sizeNum = 0
    if (-not [int]::TryParse([string]$Size, [ref]$sizeNum) -or $sizeNum -lt 1) {
        log_error "size must be a positive integer: $Size"
        return 2
    }
    if (-not (Test-Path -Path $InputSvg -PathType Leaf)) {
        log_error "input SVG not found: $InputSvg"
        return 2
    }

    $tool = svg_rasterizer
    if (-not $tool) {
        log_error "no SVG rasterizer found (install inkscape or ImageMagick)"
        return 3
    }

    $outDir = Split-Path -Parent $OutputPng
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    switch ($tool) {
        'inkscape' {
            # Inkscape 1.x syntax, with a fallback to the 0.9x flags.
            & inkscape $InputSvg --export-type=png --export-filename=$OutputPng -w $sizeNum -h $sizeNum 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & inkscape -z -e $OutputPng -w $sizeNum -h $sizeNum $InputSvg 2>$null | Out-Null
            }
        }
        default {
            # -extent on a centered gravity guarantees a square canvas.
            & $tool -background none $InputSvg -resize "${sizeNum}x${sizeNum}" `
                    -gravity center -extent "${sizeNum}x${sizeNum}" $OutputPng
        }
    }

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputPng)) {
        log_error "rasterize failed ($tool): $InputSvg -> $OutputPng"
        return 1
    }

    log_info "rasterized $InputSvg -> $OutputPng (${sizeNum}px, $tool)"
    return 0
}

<#
.SYNOPSIS
Render one PNG per size, for icon sets.

.DESCRIPTION
Writes <OutDir>/<BaseName>-<size>.png for each size given. Continues after a
failed size and returns 1 if any render failed, 2 for bad arguments.

.EXAMPLE
svg_rasterize_sizes logo.svg ./icons ic_launcher 48 72 96 144 192
#>
function svg_rasterize_sizes {
    param(
        [Parameter(Position = 0)][string]$InputSvg,
        [Parameter(Position = 1)][string]$OutDir,
        [Parameter(Position = 2)][string]$BaseName,
        [Parameter(Position = 3, ValueFromRemainingArguments)][int[]]$Sizes
    )

    if (-not $InputSvg -or -not $OutDir -or -not $BaseName -or -not $Sizes -or $Sizes.Count -lt 1) {
        log_error "usage: svg_rasterize_sizes <in.svg> <out_dir> <basename> <size> [size...]"
        return 2
    }

    $rc = 0
    foreach ($s in $Sizes) {
        $out = Join-Path $OutDir "$BaseName-$s.png"
        if ((svg_rasterize $InputSvg $out $s) -ne 0) { $rc = 1 }
    }
    return $rc
}

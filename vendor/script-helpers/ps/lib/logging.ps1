# Logging and color helpers — PowerShell companion to lib/logging.sh.
# Provides the same function names as the Bash module for cross-platform consistency.

# Detect ANSI support: PS 7+ on any platform, or when TERM indicates color.
$_SHLIB_ANSI = ($PSVersionTable.PSVersion.Major -ge 7) -or ($env:TERM -match 'color')

function _Shlib_WriteColor {
    param([string]$Color, [string]$Message, [switch]$Stderr, [switch]$InPipeline)
    $map = @{
        Red     = 'Red';     Green   = 'Green'
        Yellow  = 'Yellow';  Blue    = 'Blue'
        Cyan    = 'Cyan';    Magenta = 'Magenta'
        White   = 'White';   Gray    = 'Gray'
    }
    if ($Stderr) {
        if ($_SHLIB_ANSI -and -not [Console]::IsErrorRedirected) {
            $ansiMap = @{ Red='31'; Green='32'; Yellow='33'; Blue='34'; Cyan='36'; Magenta='35'; White='37'; Gray='90' }
            $esc  = [char]27
            $code = if ($ansiMap.ContainsKey($Color)) { $ansiMap[$Color] } else { '37' }
            [Console]::Error.WriteLine("${esc}[${code}m${Message}${esc}[0m")
        } else {
            [Console]::Error.WriteLine($Message)
        }
        return
    }
    # Treat PS pipelines the same as file redirection: emit plain text so callers can capture output.
    if ([Console]::IsOutputRedirected -or $InPipeline) {
        Write-Output $Message
    } elseif ($_SHLIB_ANSI) {
        $ansiMap = @{ Red='31'; Green='32'; Yellow='33'; Blue='34'; Cyan='36'; Magenta='35'; White='37'; Gray='90' }
        $esc  = [char]27
        $code = if ($ansiMap.ContainsKey($Color)) { $ansiMap[$Color] } else { '37' }
        Write-Output "${esc}[${code}m${Message}${esc}[0m"
    } else {
        $fc = if ($map.ContainsKey($Color)) { $map[$Color] } else { 'White' }
        Write-Host $Message -ForegroundColor $fc
    }
}

function print_color {
    param([string]$Color, [string]$Text, [string]$Text2 = '', [string]$Color2 = '')
    $inPipe = $MyInvocation.PipelineLength -gt 1
    _Shlib_WriteColor -Color $Color -Message $Text -InPipeline:$inPipe
    if ($Text2) {
        $c2 = if ($Color2) { $Color2 } else { $Color }
        _Shlib_WriteColor -Color $c2 -Message $Text2 -InPipeline:$inPipe
    }
}

function print_info    { _Shlib_WriteColor White   "[Info]: $($args -join ' ')"    -InPipeline:($MyInvocation.PipelineLength -gt 1) }
function print_error   { _Shlib_WriteColor Red    "[Error!]: $($args -join ' ')"   -InPipeline:($MyInvocation.PipelineLength -gt 1); try { [Console]::Beep(800, 200) } catch {} }
function print_success { _Shlib_WriteColor Green  "Success [OK]: $($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
function print_warning { _Shlib_WriteColor Yellow "[Warning!]: $($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1); try { [Console]::Beep(800, 200) } catch {} }
function print_line {
    if ([Console]::IsOutputRedirected -or ($MyInvocation.PipelineLength -gt 1)) { Write-Output "----------------------------------------" }
    else { Write-Host "----------------------------------------" }
}

function log_info  { _Shlib_WriteColor Green  "[INFO] $($args -join ' ')" -Stderr }
function log_warn  { _Shlib_WriteColor Yellow "[WARN] $($args -join ' ')" -Stderr }
function log_error { _Shlib_WriteColor Red    "[ERROR] $($args -join ' ')" -Stderr }
function log_debug {
    if ($env:DEBUG -eq 'true') {
        _Shlib_WriteColor Blue "[DEBUG] $($args -join ' ')" -Stderr
    }
}

function print_red     { _Shlib_WriteColor Red     "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
function print_green   { _Shlib_WriteColor Green   "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
function print_yellow  { _Shlib_WriteColor Yellow  "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
function print_blue    { _Shlib_WriteColor Blue    "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }

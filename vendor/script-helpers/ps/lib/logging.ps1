# Logging and color helpers - PowerShell companion to lib/logging.sh.
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

# Usage: print_color -Color <name> -Text <text> [-Text2 <text>] [-Color2 <name>]
# Prints one or two lines in a color (Red, Green, Yellow, Blue, Cyan, Magenta, White, Gray).
# Returns: nothing.
# Output: stdout the text (ANSI-colored on a PS 7 console, plain when redirected or piped).
function print_color {
    param([string]$Color, [string]$Text, [string]$Text2 = '', [string]$Color2 = '')
    $inPipe = $MyInvocation.PipelineLength -gt 1
    _Shlib_WriteColor -Color $Color -Message $Text -InPipeline:$inPipe
    if ($Text2) {
        $c2 = if ($Color2) { $Color2 } else { $Color }
        _Shlib_WriteColor -Color $c2 -Message $Text2 -InPipeline:$inPipe
    }
}

# Usage: print_info <words...>
# Returns: nothing.
# Output: stdout "[Info]: <words>".
function print_info    { _Shlib_WriteColor White   "[Info]: $($args -join ' ')"    -InPipeline:($MyInvocation.PipelineLength -gt 1) }
# Usage: print_error <words...>
# Returns: nothing. Does not stop the caller.
# Output: stdout "[Error!]: <words>" in red; beeps where the console supports it.
function print_error   { _Shlib_WriteColor Red    "[Error!]: $($args -join ' ')"   -InPipeline:($MyInvocation.PipelineLength -gt 1); try { [Console]::Beep(800, 200) } catch {} }
# Usage: print_success <words...>
# Returns: nothing.
# Output: stdout "Success [OK]: <words>" in green.
function print_success { _Shlib_WriteColor Green  "Success [OK]: $($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
# Usage: print_warning <words...>
# Returns: nothing.
# Output: stdout "[Warning!]: <words>" in yellow; beeps where the console supports it.
function print_warning { _Shlib_WriteColor Yellow "[Warning!]: $($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1); try { [Console]::Beep(800, 200) } catch {} }
# Usage: print_line
# Returns: nothing.
# Output: stdout a 40-character "----" rule.
function print_line {
    if ([Console]::IsOutputRedirected -or ($MyInvocation.PipelineLength -gt 1)) { Write-Output "----------------------------------------" }
    else { Write-Host "----------------------------------------" }
}

# Usage: log_info <words...>
# Returns: nothing.
# Output: stderr "[INFO] <words>".
function log_info  { _Shlib_WriteColor Green  "[INFO] $($args -join ' ')" -Stderr }
# Usage: log_warn <words...>
# Returns: nothing.
# Output: stderr "[WARN] <words>".
function log_warn  { _Shlib_WriteColor Yellow "[WARN] $($args -join ' ')" -Stderr }
# Usage: log_error <words...>
# Returns: nothing. Does not stop the caller.
# Output: stderr "[ERROR] <words>".
function log_error { _Shlib_WriteColor Red    "[ERROR] $($args -join ' ')" -Stderr }
# Usage: log_debug <words...>
# Returns: nothing.
# Output: stderr "[DEBUG] <words>", only when $env:DEBUG is 'true'.
function log_debug {
    if ($env:DEBUG -eq 'true') {
        _Shlib_WriteColor Blue "[DEBUG] $($args -join ' ')" -Stderr
    }
}

# Usage: print_red <words...>
# Returns: nothing.
# Output: stdout the words in red.
function print_red     { _Shlib_WriteColor Red     "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
# Usage: print_green <words...>
# Returns: nothing.
# Output: stdout the words in green.
function print_green   { _Shlib_WriteColor Green   "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
# Usage: print_yellow <words...>
# Returns: nothing.
# Output: stdout the words in yellow.
function print_yellow  { _Shlib_WriteColor Yellow  "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }
# Usage: print_blue <words...>
# Returns: nothing.
# Output: stdout the words in blue.
function print_blue    { _Shlib_WriteColor Blue    "$($args -join ' ')" -InPipeline:($MyInvocation.PipelineLength -gt 1) }

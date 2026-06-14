# Help/documentation helpers — PowerShell companion to lib/help.sh.
# Parses structured header comments from scripts and renders help output.
#
# Header format (same as Bash module):
#   # SCRIPT: My Script
#   # DESCRIPTION: Does something useful.
#   # USAGE: script.ps1 [OPTIONS]
#   # PARAMETERS:
#   #   -Foo  Does foo
#   # EXAMPLE: script.ps1 -Foo bar

function get_script_metadata {
    param([string]$ScriptFile)
    $meta = @{
        name=''; description=''; author=''; created=''; version='';
        usage=''; parameters=''; example=''; exit_codes=''; date=''; creator=''
    }
    if (-not $ScriptFile -or -not (Test-Path $ScriptFile)) { return $meta }

    $multiline = @('parameters','usage','example','exit_codes')
    $patterns  = @{
        name       = '^#\s*SCRIPT:\s*(.*)'
        description= '^#\s*DESCRIPTION:\s*(.*)'
        author     = '^#\s*AUTHOR:\s*(.*)'
        created    = '^#\s*CREATED:\s*(.*)'
        version    = '^#\s*VERSION:\s*(.*)'
        usage      = '^#\s*USAGE:\s*(.*)'
        parameters = '^#\s*PARAMETERS:\s*(.*)'
        example    = '^#\s*EXAMPLE:\s*(.*)'
        exit_codes = '^#\s*EXIT_CODES:\s*(.*)'
        date       = '^#\s*DATE:\s*(.*)'
        creator    = '^#\s*CREATOR:\s*(.*)'
    }

    $currentField  = ''
    $sawHeaderKey  = $false
    $inHeader      = $true

    foreach ($line in (Get-Content $ScriptFile)) {
        if ($inHeader) {
            if ($line -match '^#!') { continue }
            if ($line -notmatch '^#') {
                if ($sawHeaderKey) { break }
                continue
            }
            if ($line -match '^#\s*-{3,}') { break }
        }

        $matched = $false
        foreach ($key in $patterns.Keys) {
            if ($line -match $patterns[$key]) {
                $sawHeaderKey  = $true
                $matched       = $true
                $currentField  = if ($multiline -contains $key) { $key } else { '' }
                $meta[$key]    = $Matches[1]
                break
            }
        }

        if (-not $matched -and $currentField) {
            if ($line -match '^#\s(.*)') {
                if ($meta[$currentField]) {
                    $meta[$currentField] += "`n" + $Matches[1]
                } else {
                    $meta[$currentField] = $Matches[1]
                }
            } elseif ($line -match '^#\s*-{3,}') {
                $currentField = ''; break
            } elseif ($line -match '^#') {
                $currentField = ''
            }
        }
    }
    return $meta
}

function _Help_PrintInline {
    param([string]$Color, [string]$Label, [string]$Value)
    if (-not $Value) { return }
    if (Get-Command print_color -ErrorAction SilentlyContinue) { print_color $Color "${Label}: $Value" }
    else { Write-Output "${Label}: $Value" }
}

function _Help_PrintBlock {
    param([string]$Color, [string]$Label, [string]$Value)
    if (-not $Value) { return }
    if (Get-Command print_color -ErrorAction SilentlyContinue) { print_color $Color "${Label}:" }
    else { Write-Output "${Label}:" }
    $Value -split "`n" | ForEach-Object { Write-Output "  $_" }
}

function _Help_Render {
    param([string]$Mode, [string]$ScriptFile)
    $meta   = get_script_metadata $ScriptFile
    $usage  = if ($meta.usage) { $meta.usage } elseif ($ScriptFile) { "$([System.IO.Path]::GetFileName($ScriptFile)) [OPTIONS]" } else { 'script.ps1 [OPTIONS]' }

    if ($Mode -eq 'full' -and $meta.name)    { _Help_PrintInline 'Cyan'   'Script'      $meta.name }
    elseif ($meta.name)                       { _Help_PrintInline 'Green'  'Script Name' $meta.name }
    _Help_PrintInline 'Green' 'Usage'         $usage
    _Help_PrintBlock  'White' 'Description'   $meta.description
    _Help_PrintBlock  'White' 'Parameters'    $meta.parameters
    if ($Mode -in @('concise','minimal'))    { _Help_PrintBlock 'Yellow' 'Example' $meta.example }
    if ($Mode -eq 'full') {
        _Help_PrintInline 'White' 'Author'  $meta.author
        _Help_PrintInline 'White' 'Created' $meta.created
        _Help_PrintInline 'White' 'Version' $meta.version
    }
    if ($Mode -eq 'minimal') {
        _Help_PrintBlock  'White' 'Exit Codes' $meta.exit_codes
        _Help_PrintInline 'White' 'Version'    $meta.version
    }
    show_usage $ScriptFile
}

function display_help { param([string]$ScriptFile = $env:SHLIB_CALLER_SCRIPT); _Help_Render 'concise' $ScriptFile }
function print_help   { param([string]$ScriptFile = $env:SHLIB_CALLER_SCRIPT); _Help_Render 'full'    $ScriptFile }
function show_help    { param([string]$ScriptFile = $env:SHLIB_CALLER_SCRIPT); _Help_Render 'minimal' $ScriptFile }

function show_usage {
    param([string]$ScriptFile = '')
    $name = if ($ScriptFile) { [System.IO.Path]::GetFileName($ScriptFile) } else { 'script.ps1' }
    Write-Output @"

Usage: $name [OPTIONS]

Common Options:
  -Help, -h, --help         Show this help message
  -Verbose, -v, --verbose   Enable verbose output
  -Debug, -d, --debug       Enable debug logging

Environment Variables:
  DEBUG=true  Enable debug logging

"@
}

function parse_common_args {
    param([string[]]$Args)
    foreach ($arg in $Args) {
        switch ($arg) {
            { $_ -in '-Help', '-h', '--help' }       { $env:SHLIB_HELP_SHOWN = 'true'; show_help; exit 0 }
            { $_ -in '-Verbose', '-v', '--verbose' }  { $env:VERBOSE = 'true' }
            { $_ -in '-Debug', '-d', '--debug' }      { $env:DEBUG = 'true' }
        }
    }
}

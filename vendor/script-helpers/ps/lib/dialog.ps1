# Interactive prompt helpers - PowerShell companion to lib/dialog.sh.
#
# Windows does not have the 'dialog' ncurses utility.
# These functions provide equivalent interactive prompts using Read-Host
# and Write-Host, matching the Bash API surface as closely as possible.

# Usage: dialog_input [-Title <t>] [-Prompt <p>] [-Default <value>]
# Returns: the typed value, or Default when the reply is empty.
# Output: host the title and prompt.
function dialog_input {
    param([string]$Title = 'Input', [string]$Prompt = '', [string]$Default = '')
    Write-Host "--- $Title ---"
    $hint = if ($Default) { " [$Default]" } else { '' }
    $val  = Read-Host "$Prompt$hint"
    return $(if ($val) { $val } else { $Default })
}

# Usage: dialog_yesno [-Title <t>] [-Message <m>]
# Returns: $true for y/Y, else $false.
# Output: host the title and prompt.
function dialog_yesno {
    param([string]$Title = 'Confirm', [string]$Message = 'Proceed?')
    Write-Host "--- $Title ---"
    $resp = Read-Host "$Message [y/N]"
    return ($resp -match '^[yY]$')
}

# Usage: dialog_menu [-Title <t>] -Items <string[]> [-Prompt <p>]
# Asks until a valid number is entered.
# Returns: the selected item.
# Output: host the numbered list and prompt.
function dialog_menu {
    param([string]$Title = 'Menu', [Parameter(Mandatory)][string[]]$Items, [string]$Prompt = 'Select')
    Write-Host "--- $Title ---"
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "  $($i + 1)) $($Items[$i])"
    }
    do {
        $raw = Read-Host "$Prompt (1-$($Items.Count))"
        $n   = 0
        $ok  = [int]::TryParse($raw, [ref]$n)
        $sel = if ($ok) { $n - 1 } else { -1 }
    } while ($sel -lt 0 -or $sel -ge $Items.Count)
    return $Items[$sel]
}

# Usage: dialog_password [-Prompt <p>]
# Returns: the typed password as plain text. Input is not echoed.
# Output: host the prompt.
function dialog_password {
    param([string]$Prompt = 'Password')
    $secure = Read-Host $Prompt -AsSecureString
    $ptr    = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

# Stub: progress display using Write-Progress.
# Usage: dialog_download_file -Url <url> -Output <path> [-Title <t>]
# Returns: nothing.
# Output: a progress bar; throws when the download fails.
function dialog_download_file {
    param([string]$Url, [string]$Output, [string]$Title = 'Downloading')
    Write-Progress -Activity $Title -Status "Downloading $Url"
    $iwrArgs = @{ Uri = $Url; OutFile = $Output }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $iwrArgs['UseBasicParsing'] = $true }
    Invoke-WebRequest @iwrArgs | Out-Null
    Write-Progress -Activity $Title -Completed
}

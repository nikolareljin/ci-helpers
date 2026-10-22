# Clipboard helpers - PowerShell companion to lib/clipboard.sh.
# Set-Clipboard is built into PowerShell 5.1+ on Windows.

# Usage: copy_to_clipboard -Text <text>
# Returns: nothing.
# Output: stderr [INFO] "Copied to clipboard." (host when logging is not loaded); throws when
#   Set-Clipboard is unavailable.
function copy_to_clipboard {
    param([string]$Text)
    Set-Clipboard -Value $Text
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "Copied to clipboard." }
    else { Write-Host "Copied to clipboard." }
}

# Usage: get_from_clipboard
# Returns: the clipboard text.
# Output: none.
function get_from_clipboard {
    return Get-Clipboard
}

# Clipboard helpers — PowerShell companion to lib/clipboard.sh.
# Set-Clipboard is built into PowerShell 5.1+ on Windows.

function copy_to_clipboard {
    param([string]$Text)
    Set-Clipboard -Value $Text
    if (Get-Command log_info -ErrorAction SilentlyContinue) { log_info "Copied to clipboard." }
    else { Write-Host "Copied to clipboard." }
}

function get_from_clipboard {
    return Get-Clipboard
}

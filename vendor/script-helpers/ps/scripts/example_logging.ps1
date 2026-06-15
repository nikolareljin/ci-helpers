# SCRIPT: example_logging.ps1
# DESCRIPTION: Demonstrates the logging module of the PowerShell script-helpers library.
# USAGE: ps\scripts\example_logging.ps1
# ----------------------------------------------------

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers logging

print_line
print_info    "This is an info message"
print_success "This is a success message"
print_warning "This is a warning message"
print_error   "This is an error message (no exception raised)"
print_line

print_red    "Red text"
print_green  "Green text"
print_yellow "Yellow text"
print_blue   "Blue text"
print_line

log_info  "Stderr info log"
log_warn  "Stderr warning log"
log_error "Stderr error log"

$env:DEBUG = 'true'
log_debug "Debug log (only shown when DEBUG=true)"
$env:DEBUG = ''
log_debug "This debug line is suppressed"

print_line
print_success "example_logging.ps1 complete."

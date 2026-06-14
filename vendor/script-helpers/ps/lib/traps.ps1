# Exit/error trap helpers — PowerShell companion to lib/traps.sh.
#
# NOTE: PowerShell trap semantics differ from Bash.
# - Use $ErrorActionPreference = 'Stop' to make terminating errors the default.
# - Use try/catch or Register-EngineEvent for cleanup on exit.
# - The setup_exit_trap function registers a script block to run on engine exit.

$_SHLIB_EXIT_HANDLER = $null
# Use the literal SourceIdentifier string; the enum stringifies to "Exiting" which
# does not match the engine event's actual identifier "PowerShell.Exiting".
$_SHLIB_EXIT_SOURCE  = 'PowerShell.Exiting'

function setup_exit_trap {
    param([scriptblock]$Handler)
    # Unregister by SourceIdentifier to avoid duplicate handlers.
    # Register-EngineEvent -Action returns a PSEventJob whose .Id is the job ID,
    # not the subscription ID needed by Unregister-Event -SubscriptionId, so we
    # use -SourceIdentifier for both register and unregister.
    Unregister-Event -SourceIdentifier $script:_SHLIB_EXIT_SOURCE -ErrorAction SilentlyContinue
    $script:_SHLIB_EXIT_HANDLER = $Handler
    # Pass handler via -MessageData; event actions run in a separate runspace
    # where script-scope variables are not visible.
    Register-EngineEvent `
        -SourceIdentifier $script:_SHLIB_EXIT_SOURCE `
        -MessageData $Handler `
        -Action { if ($event.MessageData) { & $event.MessageData } } | Out-Null
}

function cleanup_on_exit {
    param([scriptblock]$Cleanup)
    setup_exit_trap $Cleanup
}

# Enable strict terminating-error mode — mirrors Bash 'set -e'.
# Writes ErrorActionPreference into the immediate caller's scope (Scope 1) so it
# applies to that script without leaking into the wider session.
function enable_strict_mode {
    Set-Variable -Name 'ErrorActionPreference' -Value 'Stop' -Scope 1
    Set-StrictMode -Version Latest
}

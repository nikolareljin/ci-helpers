# The one entry point, for PowerShell. See scripts/cli.ps1 for the verbs.
#
#   ./dev.ps1 test
#   ./dev.ps1 screenshot --device R5CRC2WANMT
#
# The Bash entry point is ./dev and takes the identical verbs.
& (Join-Path $PSScriptRoot 'scripts/cli.ps1') @args
exit $LASTEXITCODE

# SCRIPT: generate-android-keystore.ps1
# DESCRIPTION: Generate an Android signing keystore at a new output path.
# USAGE: pwsh -File ps\scripts\generate-android-keystore.ps1 -OutputPath <path>
# PARAMETERS:
#   -OutputPath <path>  Required new keystore path. Existing files are refused.
#   -Help               Show this help message.
# EXIT_CODES:
#   0  Keystore generated.
#   1  Generation failed or the output path is unsafe.
# EXAMPLE: pwsh -File ps\scripts\generate-android-keystore.ps1 -OutputPath .\release.jks
# ----------------------------------------------------
param([string]$OutputPath, [switch]$Help)
# -Help: print the header above and stop, before anything runs.
if ($Help) { foreach ($l in Get-Content -LiteralPath $PSCommandPath) { if ($l -match '^#\s*-{4,}') { break }; $l -replace '^# ?', '' }; exit 0 }
if (-not $OutputPath) { Write-Error 'generate-android-keystore: -OutputPath is required (see -Help).'; exit 1 }
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'ps/helpers.ps1')
Import-ScriptHelpers android
if (-not (android_generate_keystore -OutputPath $OutputPath)) { exit 1 }

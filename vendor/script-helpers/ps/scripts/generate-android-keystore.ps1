param([Parameter(Mandatory)][string]$OutputPath)
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'ps/helpers.ps1')
Import-ScriptHelpers android
if (-not (android_generate_keystore -OutputPath $OutputPath)) { exit 1 }

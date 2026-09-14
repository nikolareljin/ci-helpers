# Behaviour tests for ps/lib/changelog.ps1.
#
# CI only parsed and imported the PowerShell library, so the mirror kept the
# substring match the Bash module had already dropped: asking for 0.2.0 selected
# a v10.2.0 section. Parsing cannot see that; running it can.
#
# Usage: pwsh -NoProfile -File ps/tests/changelog_test.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'changelog.ps1')

$script:failures = 0
function note([string]$m)  { Write-Host "[changelog_test.ps1] $m" }
function fail([string]$m)  { Write-Host "[changelog_test.ps1][ERROR] $m"; $script:failures++ }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("changelog-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $collide = Join-Path $tmp 'collide.md'
    Set-Content -Path $collide -Value @(
        '# Changelog', '',
        '## 2026-09-10 — v10.2.0', '', '- ten point two.', '',
        '## 2026-09-05 — v0.2.0-rc.1', '', '- the candidate.', '',
        '## 2026-01-01 — v0.2.0', '', '- zero point two.'
    )
    $body = changelog_extract -File $collide -Version '0.2.0'
    if ($body -notmatch 'zero point two') { fail "0.2.0 did not select its own section (got: $body)" }
    if ($body -match 'ten point two')     { fail '0.2.0 matched the v10.2.0 section' }
    if ($body -match 'the candidate')     { fail '0.2.0 matched the v0.2.0-rc.1 section' }
    if ((changelog_extract -File $collide -Version 'v10.2.0') -notmatch 'ten point two') { fail '10.2.0 did not select its own section' }
    if ((changelog_extract -File $collide -Version '0.2.0-rc.1') -notmatch 'the candidate') { fail 'a pre-release did not select its own section' }
    if ($null -ne (changelog_extract -File $collide -Version '0.3.0' 2>$null)) { fail 'a missing version returned a body' }
    note 'extract matches a version whole'

    $bare = Join-Path $tmp 'bare.md'
    Set-Content -Path $bare -Value @('# Changelog', '', '## 0.2.0', '- bare body')
    if ((changelog_extract -File $bare -Version '0.2.0') -notmatch 'bare body') { fail 'a bare ## X.Y.Z header was not found' }
    note 'a bare version header still matches'

    # new_section's "already there" check used `.*0\.2\.0(\D|$)`, with no leading boundary.
    $ten = Join-Path $tmp 'ten.md'
    Set-Content -Path $ten -Value @('# Changelog', '', '## 2026-09-10 — v10.2.0', '', '- ten.')
    changelog_new_section -File $ten -Version '0.2.0' -Date '2026-09-13' | Out-Null
    if (-not (Select-String -Path $ten -SimpleMatch '## 2026-09-13 — v0.2.0' -Quiet)) { fail 'new_section treated 0.2.0 as present because v10.2.0 exists' }
    changelog_new_section -File $ten -Version '0.2.0' -Date '2026-09-14' | Out-Null
    if (Select-String -Path $ten -SimpleMatch 'v0.2.0' -AllMatches | Where-Object { $_.Line -match '2026-09-14' }) { fail 'new_section ran twice for the same version' }
    note 'new_section is not fooled by a version it is a substring of, and is idempotent'

    $template = changelog_extract -File $ten -Version '0.2.0'
    if (changelog_has_entries $template) { fail 'has_entries accepted the empty new_section template' }
    if (changelog_has_entries '')        { fail 'has_entries accepted an empty body' }
    if (-not (changelog_has_entries "### Added`n- A real entry.")) { fail 'has_entries rejected a real entry' }
    if (-not (changelog_has_entries '- #42 fixed')) { fail 'has_entries took a bullet mentioning #42 for a heading' }
    note 'has_entries tells a written section from an empty template'
}
finally {
    Remove-Item -Recurse -Force $tmp
}

if ($script:failures -eq 0) { note 'ALL PASSED'; exit 0 }
note "$($script:failures) FAILURE(S)"
exit 1

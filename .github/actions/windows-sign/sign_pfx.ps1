# windows-sign pfx mode. Reads its inputs from the environment:
#   CERT_B64      base64 PFX (required)
#   CERT_PW       PFX password (required)
#   TS_URL        RFC 3161 timestamp URL (empty: the default below)
#   FILES_DIR     folder whose .exe and .msi files are signed; empty: only
#                 check that the PFX opens and holds a code-signing key
#   VERIFY_TRUST  "true" (default): `signtool verify /pa` must pass
#   TS_ATTEMPTS   timestamp attempts per file (default 4)
# The PFX is checked from memory. For signing it is written to RUNNER_TEMP
# with an ACL that only the current user can read, handed to signtool with
# /f, and deleted in a finally block. Nothing is imported into a certificate
# store, so no key persists after the step.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DefaultTimestampUrl = "http://timestamp.digicert.com"
$CodeSigningOid = "1.3.6.1.5.5.7.3.3"

function Fail([string]$msg) {
  Write-Output "::error::$msg"
  exit 1
}

$b64 = [string]$env:CERT_B64
$pw = [string]$env:CERT_PW
if ([string]::IsNullOrWhiteSpace($b64) -or [string]::IsNullOrEmpty($pw)) {
  Fail "sign_mode pfx needs certificate_base64 and certificate_password (secrets WINDOWS_CERTIFICATE and WINDOWS_CERTIFICATE_PASSWORD); one is empty. See docs/windows-signing.md."
}
# Mask before anything can print them. GitHub masks each line of a multi-line
# value only when it is registered line by line.
foreach ($line in ($pw -split "`r?`n")) { if ($line) { Write-Output "::add-mask::$line" } }
Write-Output "::add-mask::$($b64.Trim())"

$tsUrl = ([string]$env:TS_URL).Trim()
if (-not $tsUrl) { $tsUrl = $DefaultTimestampUrl }
# RFC 3161 responses are signed by the TSA and checked by signtool, so plain
# http is safe; anything else, or whitespace, is refused.
if ($tsUrl -notmatch '^https?://[^\s"]+$') {
  Fail "timestamp_server must be an http(s) URL without spaces (got: $tsUrl)."
}

$attempts = 4
if ($env:TS_ATTEMPTS) { $attempts = [int]$env:TS_ATTEMPTS }

try {
  $bytes = [Convert]::FromBase64String(($b64 -replace '\s', ''))
} catch {
  Fail "certificate_base64 is not valid base64. Encode the .pfx with: base64 -w0 cert.pfx"
}

$X509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]
$Flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]
# EphemeralKeySet keeps the key in memory; macOS lacks it, so fall back there.
$probe = $null
foreach ($kf in @($Flags::EphemeralKeySet, $Flags::DefaultKeySet)) {
  try { $probe = $X509::new($bytes, $pw, $kf); break }
  catch {
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    if ($inner -isnot [System.PlatformNotSupportedException]) { break }
  }
}
if (-not $probe) {
  Fail "the PFX does not open with certificate_password (wrong password, or not a PFX file)."
}
if (-not $probe.HasPrivateKey) {
  Fail "the PFX holds no private key: export it with the key (Export-PfxCertificate, or openssl pkcs12 -export -inkey)."
}
$ekus = @($probe.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
  ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
if ($ekus.Count -gt 0 -and $ekus -notcontains $CodeSigningOid) {
  Fail "the certificate is not for code signing (no Code Signing EKU $CodeSigningOid)."
}
$now = Get-Date
if ($probe.NotAfter -lt $now) { Fail "the certificate expired on $($probe.NotAfter.ToString('u')). Renew it; see docs/windows-signing.md." }
if ($probe.NotBefore -gt $now) { Fail "the certificate is not valid until $($probe.NotBefore.ToString('u'))." }
if ($probe.NotAfter -lt $now.AddDays(30)) {
  Write-Output "::warning::the signing certificate expires on $($probe.NotAfter.ToString('u')). Renew it before then."
}
$thumb = $probe.Thumbprint
Write-Output "PFX ok: $($probe.Subject), thumbprint $thumb, valid until $($probe.NotAfter.ToString('u'))"
$probe.Dispose()

$dir = ([string]$env:FILES_DIR).Trim()
if (-not $dir) { exit 0 }

if (-not $IsWindows) { Fail "signing with a PFX needs a Windows runner (signtool)." }
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail "files folder not found: $dir" }

# signtool ships with the Windows SDK; pick the newest x64 copy instead of a
# hard-coded SDK version, and fall back to PATH.
$signtool = $null
$kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
if (Test-Path $kits) {
  $signtool = Get-ChildItem -Path $kits -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+(\.\d+){3}$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $signtool) {
  $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($cmd) { $signtool = $cmd.Source }
}
if (-not $signtool) { Fail "signtool.exe not found: install the Windows SDK signing tools on the runner." }
Write-Output "signtool: $signtool"

$files = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Extension -in '.exe', '.msi' })
if ($files.Count -eq 0) { Fail "no .exe or .msi files under $dir to sign." }

$tmpRoot = $env:RUNNER_TEMP
if (-not $tmpRoot) { $tmpRoot = [IO.Path]::GetTempPath() }
$pfxPath = Join-Path $tmpRoot ("sign-" + [guid]::NewGuid().ToString("N") + ".pfx")
try {
  # Create the file empty, lock it to the current user, then write the bytes.
  New-Item -ItemType File -Path $pfxPath | Out-Null
  $acl = New-Object System.Security.AccessControl.FileSecurity
  $acl.SetAccessRuleProtection($true, $false)
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl.SetOwner($me)
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")))
  Set-Acl -LiteralPath $pfxPath -AclObject $acl
  [IO.File]::WriteAllBytes($pfxPath, $bytes)

  foreach ($f in $files) {
    Write-Output "signing $($f.FullName)"
    & $signtool sign /f $pfxPath /p $pw /fd SHA256 /q $f.FullName
    if ($LASTEXITCODE -ne 0) { Fail "signtool sign failed ($LASTEXITCODE) on $($f.Name)." }

    $stamped = $false
    for ($i = 1; $i -le $attempts; $i++) {
      & $signtool timestamp /tr $tsUrl /td SHA256 $f.FullName
      if ($LASTEXITCODE -eq 0) { $stamped = $true; break }
      if ($i -lt $attempts) {
        $wait = [math]::Pow(2, $i)
        Write-Output "::warning::timestamp attempt $i of $attempts failed at $tsUrl; retrying in $wait s."
        Start-Sleep -Seconds $wait
      }
    }
    if (-not $stamped) { Fail "timestamping $($f.Name) failed $attempts times at $tsUrl. Retry later, or set timestamp_server to another RFC 3161 server." }

    if ($env:VERIFY_TRUST -cne "false") {
      & $signtool verify /pa /v $f.FullName
      if ($LASTEXITCODE -ne 0) { Fail "signtool verify /pa failed on $($f.Name): the signature does not chain to a trusted root." }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
    if (-not $sig.SignerCertificate -or $sig.SignerCertificate.Thumbprint -ne $thumb) {
      Fail "$($f.Name) is not signed by $thumb after signing (status: $($sig.Status))."
    }
    if (-not $sig.TimeStamperCertificate) { Fail "$($f.Name) has no timestamp after timestamping." }
    Write-Output "ok: $($f.Name) signed by $($sig.SignerCertificate.Subject), timestamped by $($sig.TimeStamperCertificate.Subject)"
  }
} finally {
  Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $pfxPath) { Write-Output "::error::could not delete $pfxPath" ; exit 1 }
}

# Certificate helpers - PowerShell companion to lib/certs.sh.
# Uses Windows Certificate Store and New-SelfSignedCertificate.
# Admin elevation is required for trust store operations.
#
# PFX (private key) export is opt-in: pass -PfxPassword to generate a .pfx file.
# The public certificate (.cer) is always written.

# Usage: generate_self_signed_cert [-DnsName <name>] [-OutputDir <dir>] [-CertName <name>] [-PfxPassword <SecureString>]
# Creates a 1-year certificate in Cert:\CurrentUser\My and exports <CertName>.cer (and .pfx with a password).
# Returns: a hashtable with CerPath, Thumbprint and, with -PfxPassword, PfxPath.
# Output: host success line; throws when the certificate cmdlets fail (Windows only).
function generate_self_signed_cert {
    param(
        [string]$DnsName      = 'localhost',
        [string]$OutputDir    = '.',
        [string]$CertName     = 'selfsigned',
        [SecureString]$PfxPassword = $null
    )
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $cert = New-SelfSignedCertificate `
        -DnsName $DnsName `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(1)

    $cerPath = Join-Path $OutputDir "$CertName.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

    $pfxPath = $null
    if ($PfxPassword) {
        $pfxPath = Join-Path $OutputDir "$CertName.pfx"
        Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $PfxPassword | Out-Null
    }

    $msg = "Certificate generated: $cerPath"
    if ($pfxPath) { $msg += " / $pfxPath" }
    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success $msg | Out-Host }

    $result = @{ CerPath = $cerPath; Thumbprint = $cert.Thumbprint }
    if ($pfxPath) { $result['PfxPath'] = $pfxPath }
    return $result
}

# Usage: trust_cert -CertPath <path>
# Imports the certificate into Cert:\LocalMachine\Root.
# Returns: $true when imported, $false when not elevated.
# Output: host success line, or stderr [WARN] when not elevated.
function trust_cert {
    param([string]$CertPath)
    if (-not (Get-Command is_admin -ErrorAction SilentlyContinue) -or -not (is_admin)) {
        if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn "Admin elevation required to trust certificates." }
        return $false
    }
    Import-Certificate -FilePath $CertPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Certificate trusted: $CertPath" | Out-Host }
    return $true
}

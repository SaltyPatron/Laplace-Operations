#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration = "$PSScriptRoot/hart-desktop-operator.json")
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../secrets/process.ps1"
$config = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $IsWindows -or $config.version -ne 1 -or $identity.User.Value -ne $config.windows_sid -or
    $identity.Name -ne $config.windows_identity) { throw 'Operator declaration does not match this Windows user.' }
foreach ($path in @($config.pgadmin,$config.openssl,$config.state,$config.work)) {
    if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'Operator installation paths must be absolute.' }
}
[void](New-Item -ItemType Directory -Path $config.state,$config.work -Force)
$certificates = @(Get-ChildItem Cert:/CurrentUser/My | Where-Object {$_.Subject -eq "CN=$($config.certificate_subject)"})
if ($certificates.Count -gt 1) { throw 'Resolve duplicate operator certificates before enrollment.' }
if ($certificates.Count -eq 0) {
    $certificate = New-SelfSignedCertificate -Type Custom -Subject "CN=$($config.certificate_subject)" `
        -FriendlyName "Laplace PostgreSQL operator - $($identity.Name)" -CertStoreLocation Cert:/CurrentUser/My `
        -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -KeyAlgorithm RSA -KeyLength 3072 `
        -HashAlgorithm SHA256 -KeySpec Signature -KeyUsage DigitalSignature -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddYears(1) -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.2','2.5.29.19={critical}{text}ca=false')
} else { $certificate = $certificates[0] }
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date).AddDays(30)) {
    throw 'An accessible operator certificate with at least 30 days remaining is required.'
}
$privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
try {
    if ($privateKey -is [Security.Cryptography.RSACng]) {
        if ($privateKey.Key.ExportPolicy -ne [Security.Cryptography.CngExportPolicies]::None -or $privateKey.Key.IsMachineKey) {
            throw 'The operator private key must be non-exportable and belong to the Windows user.'
        }
    } elseif ($privateKey -is [Security.Cryptography.RSACryptoServiceProvider]) {
        if ($privateKey.CspKeyContainerInfo.Exportable -or $privateKey.CspKeyContainerInfo.MachineKeyStore) {
            throw 'The operator private key must be non-exportable and belong to the Windows user.'
        }
    } else { throw 'Unsupported Windows private key provider.' }
} finally { $privateKey.Dispose() }
$certificatePem = "-----BEGIN CERTIFICATE-----`n" +
    [Convert]::ToBase64String($certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks).Replace("`r`n","`n") +
    "`n-----END CERTIFICATE-----`n"
[IO.File]::WriteAllText((Join-Path $config.state 'operator.crt'),$certificatePem,[Text.Encoding]::ASCII)
$opensslConfiguration = @'
# Windows CryptoAPI keys support PKCS#1 SHA-2 client signatures.
openssl_conf = laplace_init
[laplace_init]
ssl_conf = laplace_ssl
[laplace_ssl]
system_default = laplace_tls
[laplace_tls]
SignatureAlgorithms = rsa_pkcs1_sha256:rsa_pkcs1_sha384:rsa_pkcs1_sha512:ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:ecdsa_secp521r1_sha512
'@
[IO.File]::WriteAllText((Join-Path $config.state 'operator-openssl.cnf'),$opensslConfiguration)
$remoteCode = [IO.File]::ReadAllText("$PSScriptRoot/operator-access-server.py")
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteCode))
$receipts = @()
$receiptPath = Join-Path $config.work ("enrollment-"+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'.json')
foreach ($target in $config.targets) {
    if($target['authentication'] -eq 'sspi'){
        & "$PSScriptRoot/windows-operator-access.ps1" -Configuration $Configuration
        continue
    }
    $python = if ($target.remote_root) { 'sudo -n python3' } else { 'python3' }
    $command = "$python -c 'import base64;exec(base64.b64decode(`"$encoded`"))'"
    $payload = @{target=$target;role=$config.role;certificate_subject=$config.certificate_subject;certificate=$certificatePem}
    $receipt = Invoke-Program ssh @('-o','BatchMode=yes','-o','ConnectTimeout=8',$target.ssh,$command) ($payload | ConvertTo-Json -Depth 10 -Compress) 120
    $receipts += $receipt | ConvertFrom-Json
    [IO.File]::WriteAllText($receiptPath,($receipts | ConvertTo-Json -Depth 12))
    # Public server certificates come through the already authenticated host connection.
    $certCommand = "cat '$($target.server_certificate)'"
    $serverCertificate = Invoke-Program ssh @('-o','BatchMode=yes','-o','ConnectTimeout=8',$target.ssh,$certCommand)
    [IO.File]::WriteAllText((Join-Path $config.state "$($target.ssh)-postgresql.crt"),$serverCertificate,[Text.Encoding]::ASCII)
}
& (Join-Path $config.pgadmin 'python/python.exe') "$PSScriptRoot/operator-access-client.py" --configuration $Configuration --install --pgadmin
if ($LASTEXITCODE) { throw "Operator certificate verification failed. Enrollment receipt: $receiptPath" }
Write-Output "Operator certificate enrollment and pgAdmin registration verified. Receipt: $receiptPath"

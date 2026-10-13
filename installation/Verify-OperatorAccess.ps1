#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration = "$PSScriptRoot/hart-desktop-operator.json")
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -ne $config.windows_sid) { throw 'This is not the enrolled Windows operator.' }
$certificates=@(Get-ChildItem Cert:/CurrentUser/My | Where-Object {$_.Subject -eq "CN=$($config.certificate_subject)"})
if ($certificates.Count -ne 1 -or $certificates[0].NotAfter -lt (Get-Date).AddDays(30)) {
    throw 'The operator certificate is missing, ambiguous, expired or due for renewal.'
}
$key=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificates[0])
try {
    if ($key -is [Security.Cryptography.RSACng]) {
        if ($key.Key.ExportPolicy -ne [Security.Cryptography.CngExportPolicies]::None -or $key.Key.IsMachineKey) {
            throw 'The key is not confined to the Windows user store.'
        }
    } elseif ($key -is [Security.Cryptography.RSACryptoServiceProvider]) {
        if ($key.CspKeyContainerInfo.Exportable -or $key.CspKeyContainerInfo.MachineKeyStore) {
            throw 'The key is not confined to the Windows user store.'
        }
    } else { throw 'Unsupported Windows private key provider.' }
} finally { $key.Dispose() }
& (Join-Path $config.pgadmin 'python/python.exe') "$PSScriptRoot/operator-access-client.py" --configuration $Configuration --pgadmin
exit $LASTEXITCODE

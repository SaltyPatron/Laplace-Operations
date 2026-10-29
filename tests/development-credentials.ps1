#Requires -Version 7
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../development/credentials.ps1"
if (-not $IsWindows) { throw 'This acceptance check requires Windows DPAPI.' }
$directory=Join-Path ([IO.Path]::GetTempPath()) ('laplace-enrollment-' + [Guid]::NewGuid().ToString('N'))
$saved=$env:LAPLACE_DEVELOPMENT_CREDENTIALS
$env:LAPLACE_DEVELOPMENT_CREDENTIALS=Join-Path $directory 'credentials.json'
$config=[pscustomobject]@{client='fixture';bao_role='laplace-fixture-development';bao_address='https://example.invalid';identity_reference='kv/shared/identity'}
$enrollment=@{version=1;client=$config.client;role=$config.bao_role;address=$config.bao_address;role_id=[Guid]::NewGuid().ToString();secret_id=[Guid]::NewGuid().ToString()}
function Refused([scriptblock]$Action,[string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw 'An unsafe enrollment operation was accepted.'
}
try {
    $data=Join-Path $directory 'data';$work=Join-Path $directory 'work'
    $legacy=Join-Path $work 'development/keys'
    $null=New-Item -ItemType Directory -Path $legacy -Force
    $oldKey=Join-Path $legacy 'key-existing.xml'
    Set-Content -LiteralPath $oldKey -Value 'existing protected key bytes'
    Set-Content -LiteralPath (Join-Path $legacy 'revocation-existing.xml') -Value 'existing revocation bytes'
    $keyArgs=@{DataRoot=$data;WorkRoot=$work;IisInstallation=(Join-Path $directory 'missing-installation.json')}
    $keys=Initialize-DevelopmentKeyRing @keyArgs
    if($keys -ne (Join-Path $data 'services/laplace-mono-api/state/keys')){throw 'Development keys selected a temporary path.'}
    if((Get-FileHash (Join-Path $keys 'key-existing.xml')).Hash -ne (Get-FileHash $oldKey).Hash -or
        -not (Test-Path -LiteralPath (Join-Path $keys 'revocation-existing.xml'))){throw 'Key-ring migration lost key or revocation bytes.'}
    $existing=Join-Path $keys 'key-serving.xml';Set-Content -LiteralPath $existing -Value 'serving key bytes'
    $keyHash=(Get-FileHash $existing).Hash
    $null=Initialize-DevelopmentKeyRing @keyArgs
    if((Get-FileHash $existing).Hash -ne $keyHash){throw 'Idempotent migration changed a serving key.'}
    Set-Content -LiteralPath (Join-Path $legacy 'key-serving.xml') -Value 'conflicting key ID'
    Refused {Initialize-DevelopmentKeyRing @keyArgs} 'Conflicting persistent key-ring file'
    if((Get-FileHash $existing).Hash -ne $keyHash){throw 'A key-ID conflict overwrote the serving key.'}
    $keyArgs.IisInstallation=Join-Path $directory 'iis.json'
    @{directory=(Join-Path $work 'installed-service')}|ConvertTo-Json|Set-Content -LiteralPath $keyArgs.IisInstallation
    Refused {Initialize-DevelopmentKeyRing @keyArgs} 'outside the disposable work root'
    Write-DevelopmentEnrollment $config $enrollment
    $actual=Read-DevelopmentEnrollment $config
    if ($actual.secret_id -ne $enrollment.secret_id) { throw 'DPAPI round trip failed.' }
    if ((Get-Content $env:LAPLACE_DEVELOPMENT_CREDENTIALS -Raw).Contains($enrollment.secret_id)) { throw 'SecretID was saved as plaintext.' }
    $before=(Get-FileHash $env:LAPLACE_DEVELOPMENT_CREDENTIALS).Hash
    Refused { Write-DevelopmentEnrollment $config $enrollment } 'already exists'
    if ((Get-FileHash $env:LAPLACE_DEVELOPMENT_CREDENTIALS).Hash -ne $before) { throw 'Existing enrollment changed.' }
    $config.bao_address='https://another.invalid'
    Refused { Read-DevelopmentEnrollment $config } 'does not match'
    $config.bao_address='http://example.invalid'
    Refused { Get-DevelopmentBaoAddress $config } 'HTTPS origin'
    $config.bao_address='https://example.invalid'
    'corrupted ciphertext' | Set-Content -LiteralPath $env:LAPLACE_DEVELOPMENT_CREDENTIALS
    Refused { Read-DevelopmentEnrollment $config } 'Cannot decrypt'
    $env:LAPLACE_DEVELOPMENT_CREDENTIALS='relative.json'
    Refused { Get-DevelopmentCredentialPath $config } 'must be absolute'
    Write-Host 'Persistent key-ring migration, key/revocation preservation, conflict refusal, DPAPI storage and enrollment target binding passed.'
} finally {
    $env:LAPLACE_DEVELOPMENT_CREDENTIALS=$saved
    $file=Join-Path $directory 'credentials.json'
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory)) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')){throw 'Invalid enrollment fixture cleanup root.'}
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}

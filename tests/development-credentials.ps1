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
    Write-Host 'DPAPI storage, existing-file preservation, target binding and invalid-input refusal passed.'
} finally {
    $env:LAPLACE_DEVELOPMENT_CREDENTIALS=$saved
    $file=Join-Path $directory 'credentials.json'
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
}

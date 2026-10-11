#Requires -Version 7
[CmdletBinding()]
param([string]$Installation = $(if ($env:LAPLACE_DEVELOPMENT_INSTALLATION) { $env:LAPLACE_DEVELOPMENT_INSTALLATION } else { "$PSScriptRoot/installation.json" }))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/credentials.ps1"
$config = Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
if ($config.bao_role -ne "laplace-$($config.client)-development") { throw 'Development enrollment requires its own declared workload role.' }
$address = Get-DevelopmentBaoAddress $config
$paths = Get-DevelopmentSecretPaths $config
if (Test-Path -LiteralPath (Get-DevelopmentCredentialPath $config)) { $null = Read-DevelopmentEnrollment $config }
$policy = @($paths.Values | ForEach-Object { 'path "' + ($_ -replace '^kv/', 'kv/data/') + '" { capabilities = ["read"] }' })
$policy += 'path "auth/token/lookup-self" { capabilities = ["read"] }'
$policy += 'path "auth/token/revoke-self" { capabilities = ["update"] }'
$policy += 'path "sys/capabilities-self" { capabilities = ["update"] }'
$savedAddress = $env:BAO_ADDR
try {
    $env:BAO_ADDR = $address
    $null = Invoke-Program bao @('policy','write',$config.bao_role,'-') ($policy -join "`n")
    $null = Invoke-Program bao @('write',"auth/approle/role/$($config.bao_role)","token_policies=$($config.bao_role)",
        'token_no_default_policy=true','token_ttl=5m','token_max_ttl=10m','secret_id_ttl=0','secret_id_num_uses=0')
    if (-not (Test-Path -LiteralPath (Get-DevelopmentCredentialPath $config))) {
        $roleId = (Invoke-Program bao @('read','-format=json',"auth/approle/role/$($config.bao_role)/role-id") | ConvertFrom-Json).data.role_id
        $issued = (Invoke-Program bao @('write','-f','-format=json',"auth/approle/role/$($config.bao_role)/secret-id") | ConvertFrom-Json).data
        try {
            Write-DevelopmentEnrollment $config @{version=1;client=$config.client;role=$config.bao_role;address=$address;
                role_id=$roleId;secret_id=$issued.secret_id;secret_id_accessor=$issued.secret_id_accessor}
        } catch {
            $null = Invoke-Program bao @('write',"auth/approle/role/$($config.bao_role)/secret-id-accessor/destroy",'-') (@{secret_id_accessor=$issued.secret_id_accessor} | ConvertTo-Json -Compress)
            throw
        } finally { $issued=$null; $roleId=$null }
    }
    $null = Get-DevelopmentSecrets $config
    Write-Host "Enrolled $($config.bao_role) for this Windows user. ./laplace.ps1 run can now obtain credentials without an operator Bao login."
} finally { $env:BAO_ADDR = $savedAddress }

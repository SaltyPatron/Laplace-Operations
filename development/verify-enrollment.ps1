#Requires -Version 7
[CmdletBinding()]
param([string]$Installation = $(if ($env:LAPLACE_DEVELOPMENT_INSTALLATION) { $env:LAPLACE_DEVELOPMENT_INSTALLATION } else { "$PSScriptRoot/installation.json" }))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/credentials.ps1"
$config = Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
$file = Get-DevelopmentCredentialPath $config
$null = Read-DevelopmentEnrollment $config
$receipt = [ordered]@{client=$config.client;role=$config.bao_role;checked_utc=[DateTime]::UtcNow.ToString('o');checks=@{};passed=$false}
$output = Join-Path $env:LAPLACE_WORK ('operations/desktop-enrollment-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
$savedToken=$env:BAO_TOKEN; $token=$null; $revoked=$false
try {
    $acl = Get-Acl -LiteralPath $file
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18')
    if (-not $acl.AreAccessRulesProtected) { throw 'The enrollment file inherits permissions.' }
    foreach ($entry in $acl.Access) {
        if ($entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw 'The enrollment permits an unrelated principal.' }
    }
    $receipt.checks['encrypted-user-bound-file-with-private-acl']='passed'
    $env:BAO_TOKEN='intentionally-invalid-operator-token'
    $null = Get-DevelopmentSecrets $config
    $receipt.checks['all-runtime-records-readable-without-operator-login']='passed'
    $token=New-DevelopmentBaoSession $config
    $lookup=(Invoke-DevelopmentBao $config GET 'auth/token/lookup-self' $token).data
    if ($lookup.ttl -gt 600 -or $lookup.policies.Count -ne 1 -or $lookup.policies[0] -ne $config.bao_role) { throw 'Unexpected workload token lifetime or policy.' }
    $paths = @((Get-DevelopmentSecretPaths $config).Values | ForEach-Object { $_ -replace '^kv/', 'kv/data/' })
    $denied = @('kv/data/hosts/hart-prod/appdb','auth/approle/role/hart-desktop','sys/policies/acl/default')
    $caps=(Invoke-DevelopmentBao $config POST 'sys/capabilities-self' $token @{paths=@($paths + $denied)}).data
    foreach ($path in $paths) {
        if (($caps.$path -join ',') -ne 'read') { throw "Unexpected capabilities for $path" }
    }
    foreach ($path in $denied) {
        if (($caps.$path -join ',') -ne 'deny') { throw "An unrelated operation is permitted: $path" }
    }
    $receipt.checks['declared-records-read-only-and-unrelated-access-denied']='passed'
    $receipt.record_count=$paths.Count
    $blocked=$false
    try { $null=Invoke-DevelopmentBao $config GET $denied[0] $token } catch {
        if ($_.Exception.Message -notmatch 'HTTP 403') { throw }; $blocked=$true
    }
    if (-not $blocked) { throw 'The workload read another host credential.' }
    $null=Invoke-DevelopmentBao $config POST 'auth/token/revoke-self' $token @{}
    $revoked=$true; $blocked=$false
    try { $null=Invoke-DevelopmentBao $config GET $paths[0] $token } catch {
        if ($_.Exception.Message -notmatch 'HTTP 403') { throw }; $blocked=$true
    }
    if (-not $blocked) { throw 'The revoked workload token still works.' }
    $receipt.checks['actual-unrelated-read-and-revoked-token-refused']='passed'
    $null=Get-DevelopmentSecrets $config
    $receipt.checks['new-workload-session-after-revocation']='passed'
    $receipt.passed=$true
} finally {
    if ($token -and -not $revoked) { $null=Invoke-DevelopmentBao $config POST 'auth/token/revoke-self' $token @{} }
    $env:BAO_TOKEN=$savedToken
    [void](New-Item -ItemType Directory -Path (Split-Path $output) -Force)
    $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $output
    $receipt | ConvertTo-Json -Depth 4
    Write-Host "Enrollment evidence: $output"
}

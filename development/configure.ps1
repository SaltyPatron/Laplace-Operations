#Requires -Version 7
[CmdletBinding()]
param([string]$Installation = $(if ($env:LAPLACE_DEVELOPMENT_INSTALLATION) { $env:LAPLACE_DEVELOPMENT_INSTALLATION } else { "$PSScriptRoot/installation.json" }))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../secrets/process.ps1"
. "$PSScriptRoot/credentials.ps1"
$config = Read-DevelopmentConfig $Installation
if($config.PSObject.Properties['authentication'] -and $config.authentication -eq 'sspi'){
    & "$PSScriptRoot/configure-windows.ps1" -Installation $Installation
    return
}
$root = "kv/hosts/$($config.client)"
function Record([string]$Name, [hashtable]$Initial) {
    $names = @(Invoke-Program bao @('kv','list','-format=json',$root) | ConvertFrom-Json)
    if ($Name -notin $names) {
        $null = Invoke-Program bao @('kv','put','-cas=0',"$root/$Name",'-') ($Initial | ConvertTo-Json -Compress)
    }
    (Invoke-Program bao @('kv','get','-format=json',"$root/$Name") | ConvertFrom-Json).data.data
}
function Password { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant() }
function Remote([string]$Script, [hashtable]$Payload) {
    $program = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Script))
    Invoke-Program ssh @('-o','BatchMode=yes','-o','ConnectTimeout=10',$config.database_host,
        "python3 -c 'import base64;exec(base64.b64decode(`"$program`"))'") ($Payload | ConvertTo-Json -Compress)
}
$substrate = Record 'substrate' @{ database_host=$config.database_host; database=$config.substrate_database; role=$config.substrate_role; port=$config.port; password=(Password) }
$application = Record 'appdb' @{ database_host=$config.database_host; database=$config.application_database; role=$config.application_role; port=$config.port; password=(Password) }
foreach ($pair in @(@($substrate,$config.substrate_database,$config.substrate_role), @($application,$config.application_database,$config.application_role))) {
    if ($pair[0].database_host -ne $config.database_host -or $pair[0].database -ne $pair[1] -or $pair[0].role -ne $pair[2] -or $pair[0].port -ne $config.port) {
        throw 'Existing OpenBao record selects another database or identity; refusing replacement.'
    }
}
$common = @{ client_address=$config.client_address; psql=$config.psql; admin_socket=$config.admin_socket;
    admin_role=$config.admin_role; lock=$config.host_lock; port=$config.port }
Remote "$PSScriptRoot/../secrets/database-role.py" ($common + @{database=$substrate.database; role=$substrate.role; password=$substrate.password})
Remote "$PSScriptRoot/application-database.py" ($common + @{database=$application.database; role=$application.role; password=$application.password;
    owner=$config.application_owner; work=$config.remote_work; migrator=$config.migrator})
$null = Record 'laplace-api' @{operator_token=(Password)}
$substrate = $null; $application = $null
Write-Host "Development identities provisioned for $($config.client). Credentials remain in OpenBao at $root."
& "$PSScriptRoot/enroll.ps1" -Installation $Installation

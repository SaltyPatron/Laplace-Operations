#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]*$')][string]$DatabaseHost,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]*$')][string]$ClientHost,
    [Parameter(Mandatory)][string]$ClientAddress,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_-]*$')][string]$Database,
    [Parameter(Mandatory)][string]$PsqlPath,
    [Parameter(Mandatory)][string]$AdminSocket,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_-]*$')][string]$AdminRole,
    [ValidateRange(1,65535)][int]$Port = 5432,
    [ValidatePattern('^[a-z][a-z0-9_-]*$')][string]$Role = 'laplace_runtime',
    [string]$HostLock = '/run/lock/laplace/host-resource.lock'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/process.ps1"
$null = [Net.IPAddress]::Parse($ClientAddress)
$path = "kv/hosts/$ClientHost/substrate"
$names = Invoke-Program bao @('kv','list','-format=json',"kv/hosts/$ClientHost") | ConvertFrom-Json
if ('substrate' -notin @($names)) {
    $record = @{
        database_host = $DatabaseHost; database = $Database; role = $Role; port = $Port
        password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    }
    $null = Invoke-Program bao @('kv','put','-cas=0',$path,'-') ($record | ConvertTo-Json -Compress)
}
$record = (Invoke-Program bao @('kv','get','-format=json',$path) | ConvertFrom-Json).data.data
if ($record.database_host -ne $DatabaseHost -or $record.database -ne $Database -or $record.role -ne $Role -or $record.port -ne $Port) {
    throw 'Existing substrate credential names a different selection; refusing implicit replacement.'
}
$payload = @{
    database = $Database; role = $Role; password = $record.password; client_address = $ClientAddress
    psql = $PsqlPath; admin_socket = $AdminSocket; admin_role = $AdminRole; lock = $HostLock; port = $Port
}
$program = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$PSScriptRoot/database-role.py"))
$command = "python3 -c 'import base64;exec(base64.b64decode(`"$program`"))'"
Invoke-Program ssh @('-o','BatchMode=yes','-o','ConnectTimeout=10',$DatabaseHost,$command) ($payload | ConvertTo-Json -Compress)
$payload = $null; $record = $null
Write-Output "Substrate credential stored at $path; install it on the consumer before selecting this target."

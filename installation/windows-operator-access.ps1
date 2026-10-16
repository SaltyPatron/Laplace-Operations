#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration="$PSScriptRoot/hart-desktop-operator.json")
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../laplace.env.ps1"
$config=Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.User.Value -ne $config.windows_sid -or $identity.Name -ne $config.windows_identity){throw 'The Windows operator declaration does not match this account.'}
$target=@($config.targets | Where-Object {$_['authentication'] -eq 'sspi'})
if($target.Count -ne 1){throw 'Declare exactly one local Windows PostgreSQL target.'}
$target=$target[0]
if($target.host -ine $env:COMPUTERNAME){throw 'Windows operator access must target this machine.'}
$data=[IO.Path]::GetFullPath($target.data).TrimEnd('\','/')
$prefix=[IO.Path]::GetFullPath($target.prefix).TrimEnd('\','/')
$psql=Join-Path $prefix 'bin/psql.exe'
$service=Get-CimInstance Win32_Service -Filter "Name='$($target.postgres_service)'"
if(-not $service -or $service.State -ne 'Running' -or $service.PathName.Replace('\','/') -notlike ('*'+$prefix.Replace('\','/')+'/bin/pg_ctl.exe*') -or $service.PathName.Replace('\','/') -notlike ('*'+$data.Replace('\','/')+'*')){throw 'The running service differs from the selected PostgreSQL installation.'}
$addresses=@([Net.Dns]::GetHostAddresses($target.host) | ForEach-Object IPAddressToString)
$owned=@(Get-NetIPAddress | ForEach-Object IPAddress)
if(-not $addresses.Count -or @($addresses | Where-Object {$_ -notin $owned}).Count){throw 'The desktop hostname resolves outside this machine.'}
$saved=@{}
foreach($key in 'PGPASSWORD','PGPASSFILE','PGSERVICE','PGSERVICEFILE','PGSSLMODE','PGCONNECT_TIMEOUT'){$saved[$key]=[Environment]::GetEnvironmentVariable($key);Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue}
$env:PGCONNECT_TIMEOUT='8';$env:PGPASSFILE=Join-Path $config.state 'unused-no-password-file'
function Query([string]$Sql){
    $result=$Sql | & $psql -X -w -h 127.0.0.1 -p $target.port -U $config.role -d postgres -Atq -v ON_ERROR_STOP=1 -f - 2>&1
    if($LASTEXITCODE){throw "Local PostgreSQL configuration failed: $($result -join ' ')"}
    ($result -join "`n").Trim()
}
try{
    if([IO.Path]::GetFullPath((Query 'SHOW data_directory')).TrimEnd('\','/') -ine $data){throw 'The operator connection reached a different data directory.'}
    $sam,$domain=$identity.Name.Split('\')[1],$identity.Name.Split('\')[0]
    if($sam -notmatch '^[a-zA-Z0-9_-]+$' -or $domain -notmatch '^[a-zA-Z0-9_-]+$' -or $config.role -notmatch '^[a-zA-Z0-9_-]+$'){throw 'Unsupported Windows or database identity.'}
    $rules=@('# The exact Windows operator on addresses owned by this machine.')
    foreach($address in @('127.0.0.1','::1')+$addresses | Select-Object -Unique){
        $bits=if(([Net.IPAddress]::Parse($address)).AddressFamily -eq 'InterNetwork'){32}else{128}
        $rules+="hostssl all $($config.role),postgres $address/$bits sspi include_realm=1 compat_realm=1 map=laplace_operator"
    }
    $rules+=@("host all $($config.role),postgres 0.0.0.0/0 reject","host all $($config.role),postgres ::/0 reject")
    $maps=@("laplace_operator $sam@$domain $($config.role)","laplace_operator $sam@$domain postgres")
    $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $backup=Join-Path $config.work ('windows-access-'+$stamp)
    $null=New-Item -ItemType Directory -Path $backup -Force
    foreach($name in 'pg_hba.conf','pg_ident.conf','pg_hba.operator.conf','pg_ident.operator.conf'){
        $file=Join-Path $data $name
        if(Test-Path -LiteralPath $file){Copy-Item -LiteralPath $file -Destination (Join-Path $backup $name)}
    }
    foreach($pair in @(@('pg_hba.conf','pg_hba.operator.conf'),@('pg_ident.conf','pg_ident.operator.conf'))){
        $file=Join-Path $data $pair[0];$text=[IO.File]::ReadAllText($file)
        if($text -notmatch ('(?m)^include_if_exists\s+"?'+[regex]::Escape($pair[1])+'"?\s*$')){[IO.File]::WriteAllText($file,('include_if_exists '+$pair[1]+"`n"+$text))}
    }
    # Enable TLS while the current authenticated session is still accepted.
    $null=Query 'ALTER SYSTEM SET ssl = on; SELECT pg_reload_conf();'
    [IO.File]::WriteAllText((Join-Path $data 'pg_ident.operator.conf'),(($maps -join "`n")+"`n"))
    [IO.File]::WriteAllText((Join-Path $data 'pg_hba.operator.conf'),(($rules -join "`n")+"`n"))
    if((Query 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL') -ne '0'){throw 'PostgreSQL rejected the operator HBA configuration.'}
    if((Query 'SELECT count(*) FROM pg_ident_file_mappings WHERE error IS NOT NULL') -ne '0'){throw 'PostgreSQL rejected the Windows identity map.'}
    $listeners=$env:LAPLACE_PG_LISTEN_ADDRESSES
    $restart=(Query 'SHOW listen_addresses') -ine $listeners
    $null=Query "ALTER SYSTEM SET listen_addresses = '$listeners'; SELECT pg_reload_conf();"
    if($restart -or (Query "SELECT count(*) FROM pg_settings WHERE pending_restart") -ne '0'){
        $external=Query "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid()"
        if([int]$external -gt 0){throw 'Listener changes require a restart; active database sessions were left running. Apply the pending restart during an idle maintenance window.'}
        Restart-Service -Name $target.postgres_service
        $ready=$false
        for($attempt=0;$attempt -lt 15;$attempt++){
            & (Join-Path $prefix 'bin/pg_isready.exe') -h 127.0.0.1 -p $target.port -t 1 *> $null
            if($LASTEXITCODE -eq 0){$ready=$true;break}
            Start-Sleep -Seconds 1
        }
        if(-not $ready){throw 'The selected PostgreSQL service did not become ready after restart.'}
    }
    $certificate=Join-Path $data 'server.crt'
    Copy-Item -LiteralPath $certificate -Destination (Join-Path $config.state ($target.ssh+'-postgresql.crt')) -Force
    $env:PGSSLMODE='verify-full'
    $result=& $psql -X -w "host=$($target.host) port=$($target.port) user=$($config.role) dbname=postgres sslmode=verify-full sslrootcert='$($certificate.Replace('\','/'))' require_auth=sspi" -Atq -c 'SELECT current_user,system_user,ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()' 2>&1
    if($LASTEXITCODE){throw "Desktop hostname verification failed: $($result -join ' ')"}
    [ordered]@{host=$target.host;operator=$identity.Name;data=$data;service=$target.postgres_service;addresses=$addresses;verified=($result -join ' ');configuration_backup=$backup;database_reset=$false} | ConvertTo-Json -Depth 5
}finally{foreach($key in $saved.Keys){if($null -eq $saved[$key]){Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($key,$saved[$key])}}}

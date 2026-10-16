#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration="$PSScriptRoot/hart-desktop-operator.json")
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$targets=@($c.targets | Where-Object authentication -EQ sspi)
if($targets.Count -ne 1 -or $targets[0].host -ine $env:COMPUTERNAME -or
   $identity.User.Value -ne $c.windows_sid -or $identity.Name -ne $c.windows_identity){
    throw 'Select the declared operator and this Windows database host.'
}
$target=$targets[0]
. "$PSScriptRoot/../laplace.env.ps1"
foreach($pair in @(@($env:LAPLACE_PGDATA,$target.data),@($env:LAPLACE_PG_DIR,$target.prefix))){
    if([IO.Path]::GetFullPath($pair[0]).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($pair[1]).TrimEnd('\','/')){
        throw 'The resource plan and operator declaration select different installations.'
    }
}
if($env:LAPLACE_PGSERVICE -ne $target.postgres_service -or [int]$env:LAPLACE_PGPORT -ne $target.port){
    throw 'The resource plan selects a different service or port.'
}
$service=Get-CimInstance Win32_Service -Filter "Name='$($target.postgres_service)'"
if(-not $service -or $service.State -ne 'Running' -or
   $service.PathName.Replace('\','/') -notlike ('*'+$target.prefix+'/bin/pg_ctl.exe*')){
    throw 'The declared PostgreSQL service/build is not running.'
}
$saved=@{}
foreach($name in 'LAPLACE_CONNINFO','PGPASSWORD','PGPASSFILE','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGOPTIONS'){
    $saved[$name]=[Environment]::GetEnvironmentVariable($name)
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
try{
    $cert=(Join-Path $c.state 'hart-desktop-postgresql.crt').Replace('\','/')
    $env:LAPLACE_CONNINFO="host=$($target.host) port=$($target.port) user=$($c.role) dbname=postgres sslmode=verify-full sslrootcert='$cert' require_auth=sspi connect_timeout=10"
    $env:PGPASSFILE=Join-Path $c.state 'unused-no-password-file'
    . "$PSScriptRoot/../tune-pg.ps1"
    TuneLocalOrDie
    TuneValidatePlan
    $server=(TunePsql "SELECT json_build_object('data',current_setting('data_directory'),'cluster',system_identifier::text,'operator',current_user,'identity',system_user,'ssl',ssl) FROM pg_control_system(),pg_stat_ssl WHERE pid=pg_backend_pid()") -join '' | ConvertFrom-Json
    if([IO.Path]::GetFullPath($server.data).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($target.data).TrimEnd('\','/') -or
       $server.operator -ne $c.role -or $server.identity -ne $target.authentication_identity -or -not $server.ssl){
        throw 'Resource verification reached another storage or authenticated identity.'
    }
    $declared=TuneDeclared
    $rows=@(TuneReport)
    $mismatches=@($rows | Where-Object { $_.match -ne 't' -or $_.pending -eq 't' })
    $passed=$rows.Count -eq $declared.Count -and $mismatches.Count -eq 0
    [ordered]@{host=$target.host;checked_utc=[DateTime]::UtcNow.ToString('o');server=$server;
        configuration=$env:LAPLACE_CONFIG_SOURCE;plan=TunePlan;declared=$declared;observed=$rows;
        mismatch_count=$mismatches.Count;passed=$passed} | ConvertTo-Json -Depth 8
    if(-not $passed){throw "Desktop PostgreSQL resource drift: $($mismatches.Count) of $($declared.Count) declarations differ or require restart."}
}finally{
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}

#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration="$PSScriptRoot/hart-desktop-operator.json")
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $Configuration -Raw|ConvertFrom-Json
$target=@($c.targets|Where-Object authentication -EQ sspi)
if($target.Count -ne 1 -or $target[0].host -ine $env:COMPUTERNAME){throw 'Select exactly this Windows database host.'}
$target=$target[0]
$services=@(Get-CimInstance Win32_Service|Where-Object PathName -Match '(?i)\b(?:postgres|pg_ctl)\.exe\b')
if($services.Count -ne 1 -or $services[0].Name -ne $target.postgres_service -or $services[0].State -ne 'Running' -or $services[0].StartMode -ne 'Auto'){
    throw 'Expected one running, automatic custom PostgreSQL service.'
}
$psql=Join-Path $target.prefix 'bin/psql.exe'
if($services[0].PathName.Replace('\','/') -notlike ('*'+$target.prefix+'/bin/pg_ctl.exe*')){throw 'The database service uses a different PostgreSQL build.'}
$saved=@{}
foreach($name in 'PGPASSWORD','PGPASSFILE','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGSSLMODE','PGSSLROOTCERT','PGREQUIREAUTH','PGCONNECT_TIMEOUT'){
    $saved[$name]=[Environment]::GetEnvironmentVariable($name)
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
function Query([string]$Sql){
    $result=& $psql -X -w -h $target.host -p $target.port -U $c.role -d postgres -Atq -v ON_ERROR_STOP=1 -c $Sql 2>&1
    if($LASTEXITCODE){throw ($result -join "`n")}
    ($result -join "`n").Trim()
}
try{
    $env:PGSSLMODE='verify-full';$env:PGSSLROOTCERT=Join-Path $c.state 'hart-desktop-postgresql.crt'
    $env:PGREQUIREAUTH='sspi';$env:PGCONNECT_TIMEOUT='10';$env:PGPASSFILE=Join-Path $c.state 'unused-no-password-file'
    $addresses=@([Net.Dns]::GetHostAddresses($target.host)|ForEach-Object IPAddressToString)
    $connections=@()
    foreach($address in $addresses){
        $env:PGHOSTADDR=$address
        $identity=Query 'SELECT current_user,system_user,ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()'
        if($identity -ne ($c.role+'|'+$target.authentication_identity+'|t')){throw 'Hostname access did not use the declared Windows identity and TLS.'}
        $connections+=@{address=$address;identity=$identity}
    }
    if([IO.Path]::GetFullPath((Query 'SHOW data_directory')) -ine [IO.Path]::GetFullPath($target.data)){throw 'Wrong database storage selected.'}
    if((Query 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL') -ne '0' -or (Query 'SELECT count(*) FROM pg_ident_file_mappings WHERE error IS NOT NULL') -ne '0'){throw 'PostgreSQL reports invalid authentication rules.'}
    $cluster=Query 'SELECT system_identifier FROM pg_control_system()'
    $wal=Get-Item -LiteralPath (Join-Path $target.data 'pg_wal')
    $clients=@()
    $env:PGPASSWORD='invalid-ambient-password-must-not-be-used'
    foreach($name in 'laplace-mono','laplace'){
        $command=Join-Path $env:LOCALAPPDATA "Laplace/bin/$name.cmd"
        $where=& $command --where
        if($LASTEXITCODE){throw "$name cannot resolve its installed selection."}
        $selection=$where|ConvertFrom-Json
        if($selection.database_host -ine $target.host){throw "$name selects another environment."}
        if($name -eq 'laplace'){
            $status=& $command status 2>&1
            if($LASTEXITCODE -or @($status|Where-Object {$_ -match "the same as this engine's"}).Count -ne 2){throw 'Modular SQL and client artifacts do not agree.'}
        }else{
            $status=& $command inspect Laplace 2>&1
            if($LASTEXITCODE){throw 'Installed monorepo client cannot query the local substrate.'}
        }
        $clients+=$selection
    }
    $readyResp=Invoke-WebRequest https://dev.hartonomous.com/health/ready -TimeoutSec 20 -SkipHttpErrorCheck
    $ready=$readyResp.Content|ConvertFrom-Json
    if(-not $ready.substrate_reachable -or -not $ready.perfcache_ready){throw 'Installed desktop IIS substrate or native perfcache is unavailable.'}
    [ordered]@{host=$target.host;checked_utc=[DateTime]::UtcNow.ToString('o');service=$services[0].Name;cluster=$cluster;
        data=$target.data;wal=$wal.Target;connections=$connections;clients=$clients;iis_ready=$ready.ready;iis_seeded=([bool]$ready.has_entities -and [bool]$ready.has_consensus);passed=$true}|ConvertTo-Json -Depth 6
}finally{
    foreach($name in $saved.Keys){if($null -eq $saved[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
}

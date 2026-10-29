#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration="$PSScriptRoot/hart-desktop-operator.json", [string]$ModularInstallation,
    [ValidateSet('all','monorepo','modular')][string]$Scope='all',
    [ValidateSet('none','source-interpretation','sql-foundation')][string]$Proof='none')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/desktop-clients.ps1"
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
foreach($name in 'PGPASSWORD','PGPASSFILE','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGSSLMODE','PGSSLROOTCERT','PGREQUIREAUTH','PGCONNECT_TIMEOUT',
    'PGHOST','PGPORT','PGUSER','PGOPTIONS','PSQL','LAPLACE_TIER0','LAPLACE_FLAGS','LAPLACE_HIGHWAY','LAPLACE_GRAMMARS'){
    $saved[$name]=[Environment]::GetEnvironmentVariable($name)
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
function Query([string]$Sql,[string]$Database='postgres'){
    $result=& $psql -X -w -h $target.host -p $target.port -U $c.role -d $Database -Atq -v ON_ERROR_STOP=1 -c $Sql 2>&1
    if($LASTEXITCODE){throw ($result -join "`n")}
    ($result -join "`n").Trim()
}
function Invoke-InstalledClient([string]$Command,[string[]]$Arguments){
    $output=@(& $Command @Arguments 2>&1)
    $exitCode=$LASTEXITCODE
    if($exitCode){
        Write-Host "$Command $($Arguments -join ' ') output:"
        foreach($line in $output){Write-Host ([string]$line)}
        throw "Installed client failed (exit $exitCode): $Command $($Arguments -join ' ')"
    }
    $output
}
try{
    $env:PGSSLMODE='verify-full';$env:PGSSLROOTCERT=Join-Path $c.state 'hart-desktop-postgresql.crt'
    $env:PGREQUIREAUTH='sspi';$env:PGCONNECT_TIMEOUT='10';$env:PGPASSFILE=Join-Path $c.state 'unused-no-password-file'
    if ($Proof -ne 'none') {
        if (-not $env:LAPLACE_ACCEPTANCE_WORK -or -not $env:LAPLACE_ACCEPTANCE_RESULTS) {
            throw 'Run this proof through laplace-ops test -Check so its workspace and evidence have an owner.'
        }
        $env:PGHOST=$target.host;$env:PGPORT=[string]$target.port;$env:PGUSER=$c.role;$env:PSQL=$psql
        $source=Join-Path $env:LAPLACE_SRC 'Laplace'
        if ($Proof -eq 'source-interpretation') {
            $command=Join-Path $env:LOCALAPPDATA 'Laplace/bin/laplace.cmd'
            $selection=(Invoke-InstalledClient $command @('--where'))|ConvertFrom-Json
            if ($selection.database_host -ine $target.host) { throw 'Installed Engine selects another host.' }
            $installed=Get-Content -LiteralPath $selection.installation -Raw|ConvertFrom-Json
            $env:LAPLACE_TIER0=$installed.tier0;$env:LAPLACE_FLAGS=$installed.flags
            $env:LAPLACE_HIGHWAY=$installed.highway;$env:LAPLACE_GRAMMARS=$installed.grammars
            & py -3 -X utf8 (Join-Path $env:LAPLACE_SRC 'Laplace-Engine/tests/semantic-interpretation.py') $selection.executable --recipes (Join-Path $selection.release 'share/recipes') --database
        } else {
            $command=Join-Path $env:LOCALAPPDATA 'Laplace/bin/laplace-mono.cmd'
            $selection=(Invoke-InstalledClient $command @('--where'))|ConvertFrom-Json
            if ($selection.database_host -ine $target.host) { throw 'Installed monorepo selects another host.' }
            & py -3 -X utf8 (Join-Path $source 'tests/sql-native-foundation.py') --pgbin (Join-Path $target.prefix 'bin') --source-database $selection.database_name --results $env:LAPLACE_ACCEPTANCE_RESULTS
        }
        if ($LASTEXITCODE) { throw "Installed $Proof proof failed with exit $LASTEXITCODE." }
        @{proof=$Proof;scope=$Scope;selection=$selection;passed=$true}|ConvertTo-Json -Depth 8
        exit 0
    }
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
    $clients=@();$substrates=@()
    $env:PGPASSWORD='invalid-ambient-password-must-not-be-used'
    $commands=switch($Scope){'monorepo'{@('laplace-mono')};'modular'{@('laplace')};default{@('laplace-mono','laplace')}}
    foreach($name in $commands){
        $command=Join-Path $env:LOCALAPPDATA "Laplace/bin/$name.cmd"
        $where=Invoke-InstalledClient $command @('--where')
        $selection=$where|ConvertFrom-Json
        if($selection.database_host -ine $target.host){throw "$name selects another environment."}
        $database=if($name -eq 'laplace'){$selection.database}else{$selection.database_name}
        $contract=@'
SELECT bool_and(to_regprocedure(format('%I.%I(%s)',n.nspname,api.name,api.arguments)) IS NOT NULL)
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
CROSS JOIN (VALUES ('laplace_stage_own','bigint,regclass[]'),('laplace_stage_retire',''),
 ('laplace_accumulate_series','regclass,regclass'),
 ('laplace_attest_stage','regclass,regclass'),('laplace_present_stage','regclass,regclass,name,name')) api(name,arguments)
WHERE e.extname='laplace';
'@
        if((Query $contract $database) -ne 't'){throw "$name database '$database' lacks the Native ingestion lifecycle API. The selected client and substrate have not been upgraded together."}
        $substrates+=@{database=$database;native_ingest_api='passed'}
        if($name -eq 'laplace'){
            $status=Invoke-InstalledClient $command @('status')
            if(@($status|Where-Object {$_ -match "the same as this engine's"}).Count -ne 2){
                foreach($line in $status){Write-Host ([string]$line)}
                throw 'Modular SQL and client artifacts do not agree.'
            }
        }else{
            $null=Invoke-InstalledClient $command @('inspect','Laplace')
        }
        $clients+=$selection
    }
    $ready=$null
    if($Scope -ne 'modular'){
        $readyResp=Invoke-WebRequest https://dev.hartonomous.com/health/ready -TimeoutSec 20 -SkipHttpErrorCheck
        $ready=$readyResp.Content|ConvertFrom-Json
        if(-not $ready.substrate_reachable -or -not $ready.perfcache_ready){throw 'Installed desktop IIS substrate or native perfcache is unavailable.'}
    }
    [ordered]@{host=$target.host;checked_utc=[DateTime]::UtcNow.ToString('o');service=$services[0].Name;cluster=$cluster;
        data=$target.data;wal=$wal.Target;connections=$connections;clients=$clients;substrates=$substrates;
        scope=$Scope;modular_clients=$(if($Scope -ne 'monorepo'){Get-DesktopClientState -Declaration (Get-DesktopClientDeclaration $ModularInstallation)});
        iis_ready=$ready.ready;iis_seeded=([bool]$ready.has_entities -and [bool]$ready.has_consensus);passed=$true}|ConvertTo-Json -Depth 10
}finally{
    foreach($name in $saved.Keys){if($null -eq $saved[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
}

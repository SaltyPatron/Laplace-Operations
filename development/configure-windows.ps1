#Requires -Version 7
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Installation)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/credentials.ps1"
$c=Read-DevelopmentConfig $Installation
if($c.authentication -ne 'sspi' -or $c.database_host -ine $env:COMPUTERNAME){throw 'This operation configures the declared local Windows development database.'}
foreach($value in $c.substrate_database,$c.application_database,$c.substrate_role,$c.application_role,$c.application_owner,$c.admin_role){if($value -notmatch '^[a-zA-Z0-9_-]+$'){throw 'Invalid database or role declaration.'}}
$psql=Join-Path $env:LAPLACE_PG_DIR 'bin/psql.exe'
function Query([string]$Sql,[string]$Database='postgres'){
    $output=$Sql | & $psql -X -w -h $c.database_host -p $c.port -U $c.admin_role -d $Database -Atq -v ON_ERROR_STOP=1 -f - 2>&1
    if($LASTEXITCODE){throw "Windows development database configuration failed: $($output -join ' ')"}
    ($output -join "`n").Trim()
}
$data=Query 'SHOW data_directory'
if([IO.Path]::GetFullPath($data) -ine [IO.Path]::GetFullPath($env:LAPLACE_PGDATA)){throw 'The selected connection reaches another data directory.'}
foreach($role in $c.substrate_role,$c.application_role,$c.application_owner){
    $flags=Query "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname='$role'"
    if($flags -eq 't'){throw "Refusing to repurpose privileged role $role."}
    $login=if($role -eq $c.application_owner){'NOLOGIN'}else{'LOGIN'}
    if(-not $flags){$null=Query "CREATE ROLE $role $login NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"}
    $null=Query "ALTER ROLE $role $login PASSWORD NULL"
}
foreach($pair in @(@($c.substrate_database,$c.substrate_role),@($c.application_database,$c.application_role))){
    $null=Query ('REVOKE CONNECT ON DATABASE "'+$pair[0]+'" FROM PUBLIC; GRANT CONNECT ON DATABASE "'+$pair[0]+'" TO '+$pair[1]+';')
}
$null=Query "GRANT pg_read_all_stats, pg_signal_backend TO $($c.substrate_role);"
$schemas=(Query "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname NOT IN ('information_schema','app') ORDER BY nspname" $c.substrate_database) -split "`n"
# The substrate role seeds, so it also refreshes the statistics of what it writes: since PostgreSQL 17
# ANALYZE needs MAINTAIN on the table and every leaf partition, and skips the rest with only a WARNING,
# leaving a seeded database reading as empty (Laplace#1879). Defaults cover tables created later, for the
# administrator and for every role that owns the schema or a table in it (db-reset creates the extension's
# tables as postgres).
foreach($schema in $schemas){
    if($schema -notmatch '^[a-zA-Z0-9_]+$'){throw 'Unexpected substrate schema.'}
    $permissions=if($schema -eq 'public'){'SELECT'}else{'SELECT,INSERT,UPDATE,DELETE,MAINTAIN'}
    $owners=@($c.admin_role)+@((Query "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='$schema' UNION SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relnamespace='$schema'::regnamespace AND relkind IN ('r','p') ORDER BY 1" $c.substrate_database) -split "`n" | Where-Object {$_})
    $defaults=foreach($owner in @($owners | Select-Object -Unique | Where-Object {$_ -ne $c.substrate_role})){
        if($owner -notmatch '^[a-zA-Z0-9_]+$'){throw 'Unexpected substrate table owner.'}
        "ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA $schema GRANT $permissions ON TABLES TO $($c.substrate_role); ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA $schema GRANT USAGE,SELECT ON SEQUENCES TO $($c.substrate_role);"
    }
    $null=Query "GRANT USAGE ON SCHEMA $schema TO $($c.substrate_role); GRANT $permissions ON ALL TABLES IN SCHEMA $schema TO $($c.substrate_role); GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA $schema TO $($c.substrate_role); GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA $schema TO $($c.substrate_role); $($defaults -join ' ')" $c.substrate_database
}
$null=Query ('ALTER DATABASE "'+$c.application_database+'" OWNER TO '+$c.application_owner+';')
$null=Query "ALTER SCHEMA app OWNER TO $($c.application_owner); GRANT USAGE ON SCHEMA app TO $($c.application_role); GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA app TO $($c.application_role); GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA app TO $($c.application_role); REVOKE CREATE ON SCHEMA public FROM PUBLIC;" $c.application_database
foreach($owner in $c.application_owner,$c.admin_role){$null=Query "ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA app GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO $($c.application_role); ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA app GRANT USAGE,SELECT ON SEQUENCES TO $($c.application_role);" $c.application_database}
$addresses=@('127.0.0.1','::1')+@([Net.Dns]::GetHostAddresses($c.database_host) | ForEach-Object IPAddressToString)
$owned=@(Get-NetIPAddress | ForEach-Object IPAddress)
if(@($addresses | Where-Object {$_ -notin $owned}).Count){throw 'A declared local database address is not owned by this machine.'}
$rules=@();$maps=@()
foreach($principal in $c.windows_identities){
    $account=[Security.Principal.NTAccount]::new($principal)
    $null=$account.Translate([Security.Principal.SecurityIdentifier])
    $domain,$sam=$principal.Split('\',2)
    if(-not $domain -or -not $sam -or $principal -match '["\r\n]'){throw 'Invalid Windows workload principal.'}
    foreach($role in $c.substrate_role,$c.application_role){$maps+='laplace_development "'+$sam+'@'+$domain+'" '+$role}
}
foreach($pair in @(@($c.substrate_database,$c.substrate_role),@($c.application_database,$c.application_role))){
    foreach($address in $addresses | Select-Object -Unique){$bits=if($address.Contains(':')){128}else{32};$rules+="hostssl $($pair[0]) $($pair[1]) $address/$bits sspi map=laplace_development include_realm=1 compat_realm=1"}
    $rules+="host all $($pair[1]) 0.0.0.0/0 reject";$rules+="host all $($pair[1]) ::/0 reject"
}
$backup=Join-Path $env:LAPLACE_WORK ('operations/windows-development-access-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
$null=New-Item -ItemType Directory -Path $backup
foreach($pair in @(@('pg_hba.conf','pg_hba.development.conf',$rules),@('pg_ident.conf','pg_ident.development.conf',$maps))){
    $file=Join-Path $data $pair[0];$include=Join-Path $data $pair[1]
    Copy-Item -LiteralPath $file -Destination (Join-Path $backup $pair[0])
    if(Test-Path -LiteralPath $include){Copy-Item -LiteralPath $include -Destination (Join-Path $backup $pair[1])}
    [IO.File]::WriteAllText($include,(($pair[2] -join "`n")+"`n"))
    $text=[IO.File]::ReadAllText($file)
    if($text -notmatch ('(?m)^include_if_exists '+[regex]::Escape($pair[1])+'\s*$')){[IO.File]::WriteAllText($file,('include_if_exists '+$pair[1]+"`n"+$text))}
}
if((Query 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL') -ne '0' -or (Query 'SELECT count(*) FROM pg_ident_file_mappings WHERE error IS NOT NULL') -ne '0'){throw 'PostgreSQL rejected a Windows development authentication rule.'}
$null=Query 'SELECT pg_reload_conf()'
'Configured distinct Windows-authenticated development roles for '+$c.substrate_database+' and '+$c.application_database+'.'
if($c.uci -and $env:LAPLACE_IIS_INSTALLATION -and (Test-Path -LiteralPath $env:LAPLACE_IIS_INSTALLATION)){
    & "$PSScriptRoot/../installation/desktop-uci.ps1" -Development $Installation -IisInstallation $env:LAPLACE_IIS_INSTALLATION
}

#Requires -Version 7
[CmdletBinding()]
param([string]$Installation = $(if ($env:LAPLACE_DEVELOPMENT_INSTALLATION) { $env:LAPLACE_DEVELOPMENT_INSTALLATION } else { "$PSScriptRoot/installation.json" }))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/../secrets/process.ps1"
. "$PSScriptRoot/credentials.ps1"
$config = Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
$psql = Join-Path $env:LAPLACE_PG_DIR 'bin/psql.exe'
$saved = @{}
foreach ($name in 'PGPASSWORD','PGSSLMODE','PGSSLROOTCERT','PGREQUIREAUTH','PGPASSFILE','PGSERVICE','PGSERVICEFILE','PGCONNECT_TIMEOUT') { $saved[$name] = [Environment]::GetEnvironmentVariable($name); Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
$receipt = [ordered]@{ host=$config.database_host; client=$config.client; checked_utc=[DateTime]::UtcNow.ToString('o'); checks=@{}; passed=$false }
$output = Join-Path $env:LAPLACE_WORK ('operations/desktop-identities-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
function Query($Record, [string]$Sql, [string]$Database = $Record.database) {
    $env:PGPASSWORD = $Record.password
    $env:PGSSLMODE = 'require'
    if($config.PSObject.Properties['authentication'] -and $config.authentication -eq 'sspi'){
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        $env:PGSSLMODE='verify-full';$env:PGSSLROOTCERT=$config.root_certificate;$env:PGREQUIREAUTH='sspi'
        $env:PGPASSFILE=Join-Path $env:LAPLACE_WORK 'unused-no-password-file'
    }
    $env:PGCONNECT_TIMEOUT = '10'
    (Invoke-Program $psql @('-X','-w','-At','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate','-h',$Record.database_host,
        '-p',[string]$Record.port,'-U',$Record.role,'-d',$Database,'-f','-') $Sql).Trim()
}
function Denied($Record, [string]$Sql, [string]$Code, [string]$Database = $Record.database) {
    try { $null = Query $Record $Sql $Database } catch {
        if ($_.Exception.Message -match "\b($Code)\b") { return }
        # libpq omits SQLSTATE from connection-establishment errors even when
        # psql's statement verbosity requests it. Require this specific HBA denial.
        if ($Code -eq '28000' -and $_.Exception.Message -match 'FATAL:\s+(no pg_hba\.conf entry|pg_hba\.conf rejects connection)') { return }
        throw "The denial probe failed for an unexpected reason (expected $Code): $($_.Exception.Message)"
    }
    throw 'The runtime identity accepted a prohibited operation.'
}
try {
    if($config.PSObject.Properties['authentication'] -and $config.authentication -eq 'sspi'){
        $records=@{}
        foreach($pair in @(@('substrate',$config.substrate_database,$config.substrate_role),@('appdb',$config.application_database,$config.application_role))){
            $records[$pair[0]]=[pscustomobject]@{database_host=$config.database_host;port=$config.port;database=$pair[1];role=$pair[2];password=$null}
        }
    }else{$records = Get-DevelopmentSecrets $config}
    foreach ($kind in 'substrate','appdb') {
        $record = $records[$kind]
        if ((Query $record 'SELECT current_user') -ne $record.role) { throw 'Connected as the wrong database identity.' }
        if ((Query $record "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname=current_user") -ne 'f') { throw 'Runtime identity is privileged.' }
        Denied $record "SET ROLE $($config.admin_role)" '42501'
        $receipt.checks["$kind-login-and-admin-denial"] = 'passed'
    }
    $application = $records.appdb; $substrate = $records.substrate
    $null = Query $application 'SELECT count(*) FROM app.api_keys'
    Denied $application 'BEGIN; CREATE TABLE public.laplace_permission_probe(id integer); ROLLBACK;' '42501'
    Denied $application 'BEGIN; CREATE TABLE app.laplace_permission_probe(id integer); ROLLBACK;' '42501'
    Denied $substrate 'SELECT count(*) FROM app.api_keys' '42501|42P01|3F000'
    Denied $substrate 'SELECT 1' '28000' $application.database
    Denied $application 'SELECT 1' '28000' $substrate.database
    $receipt.checks['application-data-readable-runtime-ddl-denied'] = 'passed'
    $receipt.checks['substrate-cannot-read-application-identities'] = 'passed'
    $receipt.checks['cross-database-connections-denied'] = 'passed'
    $receipt.passed = $true
} finally {
    foreach ($name in $saved.Keys) { if($null -eq $saved[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')} }
    [void](New-Item -ItemType Directory -Path (Split-Path $output) -Force)
    $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $output
    $receipt | ConvertTo-Json -Depth 4
    Write-Host "Identity evidence: $output"
}

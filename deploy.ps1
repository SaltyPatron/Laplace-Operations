#Requires -Version 7
<#
  Laplace on Windows, from an empty server to a Laplace database ready to be loaded: deploy.sh's counterpart. The build,
  the independently prepared perf-caches, the grammars, the database with its extension and
  schema, and its status. No data is loaded here. Everything it does can be done again.
    pwsh -File deploy.ps1                                        the database laplace.env.ps1 names
    $env:LAPLACE_CONNINFO = '... dbname=NAME'; pwsh -File deploy.ps1   another database; made if the server does not have it
    pwsh -File deploy.ps1 drop                                   the database dropped first and made again, empty
    pwsh -File deploy.ps1 -Installed [drop]                       use the installed client and caches, without a build
  What it needs first: setup.ps1 run (the server, its settings, its access), and the data under LAPLACE_DATA. What each
  step said is kept in $LAPLACE_WORK\logs\deploy.
#>
param([string]$Drop = '',[switch]$Installed)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if($Installed){
    . "$PSScriptRoot/installation/desktop-clients.ps1"
    . "$PSScriptRoot/installation/storage.ps1"
    $declared=Get-DesktopClientDeclaration
    $operation=Enter-DesktopStorageOperation
    $run=Join-Path $env:LAPLACE_WORK ('operations/modular-database-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
    $null=New-Item -ItemType Directory -Path $run
    $receipt=@{host=$declared.host;database=$declared.database;operation=$(if($Drop -eq 'drop'){'recreate'}else{'migrate'});completed=$false}
    try{
        if($Drop -and $Drop -ne 'drop'){throw 'The installed deployment accepts only an explicit drop or no drop.'}
        $profile=Read-StorageJson $declared.operator_client.configuration
        if(-not $profile -or [IO.Path]::GetFullPath($profile.installation) -ine [IO.Path]::GetFullPath($declared.installed_config)){throw 'The operator client does not select the declared modular installation.'}
        $selected=Read-StorageJson $profile.installation
        if($selected.host -ine $declared.host -or $selected.socket -ine $declared.socket -or $selected.database -cne $declared.database){throw 'The installed database differs from the declared modular target.'}
        $receipt.installation=$profile.installation;$receipt.release=$selected.release
        $options=if($Drop -eq 'drop'){@('--drop')}else{@()}
        & py -3 "$PSScriptRoot/installation/deploy-client.py" --configuration $declared.operator_client.configuration --psql (Join-Path $env:LAPLACE_PG_DIR 'bin/psql.exe') @options 2>&1 | Tee-Object -FilePath (Join-Path $run 'deploy.log')
        if($LASTEXITCODE){throw "Installed database deployment exited $LASTEXITCODE. See $run/deploy.log"}
        $receipt.completed=$true
    }finally{
        $receipt.finished_utc=[DateTime]::UtcNow.ToString('o');$receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run 'receipt.json')
        Write-Host "Receipt: $run/receipt.json"
        Exit-DesktopStorageOperation -Operation $operation
    }
    return
}
$db = if ($env:LAPLACE_CONNINFO -match 'dbname=(\S+)') { $Matches[1] } else { 'default' }
New-Item -ItemType Directory -Force $env:LAPLACE_LOCKS | Out-Null
# one deployment per database at a time, whoever runs it: the lock is held open, no sharing, while this runs; the
# second says so and leaves. Never under an ingest: it rebuilds the program the ingest runs and changes the schema.
try { $deployLock = [IO.File]::Open((Join-Path $env:LAPLACE_LOCKS "deploy-$db.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { "a deployment of $db is already running: this one leaves"; exit 3 }
$ingest = Join-Path $env:LAPLACE_LOCKS "ingest-$db.lock"
if (Test-Path $ingest) { try { ([IO.File]::Open($ingest, 'Open', 'ReadWrite', 'None')).Close() } catch { "an ingest of $db is running: this deployment leaves; run it again when the ingest is done"; exit 3 } }

$env:PATH = "$env:LAPLACE_BUILD\Laplace-Engine\icx-release;$env:LAPLACE_PG_DIR\bin;$env:LAPLACE_ICU_DIR\bin64;$env:PATH"
$psql = Join-Path $env:LAPLACE_PG_DIR 'bin\psql.exe'
# Refuse missing artifacts before changing the database, including an explicit drop.
$flags = if ($env:LAPLACE_FLAGS) { $env:LAPLACE_FLAGS } else { $env:LAPLACE_TIER0 -replace '\.bin$', '.flags' }
foreach ($artifact in @($env:LAPLACE_TIER0, $flags, "$flags.layout", $env:LAPLACE_HIGHWAY)) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-Item -LiteralPath $artifact).Length -eq 0) {
        throw "missing deployment artifact: $artifact; prepare or install the perf-caches separately (README.md)"
    }
}
# deploy.ps1 drop: the database dropped and made again, empty, by the role, which may drop databases (the cluster
# itself is setup.ps1 drop's, run by a person)
if ($Drop -eq 'drop') {
    if (-not $db -or $db -eq 'postgres' -or $db -eq 'default') { "deploy.ps1 drop: LAPLACE_CONNINFO names no database of Laplace's"; exit 2 }
    & $psql -X ($env:LAPLACE_CONNINFO -replace 'dbname=\S+', 'dbname=postgres') -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS `"$db`" WITH (FORCE)"
    if ($LASTEXITCODE) { exit 1 }
    "=== $db dropped: it is made again below"
}
$log = Join-Path $env:LAPLACE_WORK ("logs\deploy\{0:yyyyMMddTHHmmssZ}" -f (Get-Date).ToUniversalTime()); New-Item -ItemType Directory -Force $log | Out-Null
function Step([string]$name, [scriptblock]$body) {
    ''; "=== $name   {0:HH:mm:ss}" -f (Get-Date).ToUniversalTime()
    $global:LASTEXITCODE = 0
    & $body 2>&1 | Where-Object { "$_" -notmatch '^OMP: ' } | Tee-Object -FilePath (Join-Path $log "$name.log")
    if ($LASTEXITCODE) { "=== $name did not finish; what it said is in $log\$name.log"; exit 1 }
}

Step tune-pg  { & pwsh.exe -NoProfile -File (Join-Path $PSScriptRoot 'tune-pg.ps1') }       # the server's settings: apply, reload, check. a drift fails the deploy
Step build    { & pwsh.exe -NoProfile -File (Join-Path $PSScriptRoot 'build.ps1') install }
Step highway-fingerprint { & laplace.exe highway --fingerprint }
if (-not (Get-ChildItem $env:LAPLACE_GRAMMARS -ErrorAction SilentlyContinue)) {
    Step grammars { & 'C:\Program Files\Git\bin\bash.exe' (Join-Path $env:LAPLACE_SRC 'Laplace-Engine\tools\build_grammars.sh') $env:LAPLACE_GRAMMAR_SRC $env:LAPLACE_GRAMMARS }
}
Step deploy   { & laplace.exe deploy --configure-server-cache }
Step status   { & laplace.exe status }
$deployLock.Close()
''; "=== done   {0:HH:mm:ss}   $log" -f (Get-Date).ToUniversalTime()

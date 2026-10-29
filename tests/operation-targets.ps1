#Requires -Version 7
# Check CLI dispatch only. Deployment evidence comes from the real GitHub run.
$ErrorActionPreference='Stop'
$entry=(Resolve-Path "$PSScriptRoot/../laplace.ps1").Path
function Dispatch([string[]]$Arguments) {
    $quoted=@($Arguments | ForEach-Object { if ($_ -in '-Target','-SourcePath','-Database','-DatabaseOperation','-Yes','-Force','-Check','-List') { $_ } else { "'" + $_.Replace("'", "''") + "'" } }) -join ' '
    $program=@"
function gh {
    `$global:LASTEXITCODE=0
    'DISPATCH:' + (ConvertTo-Json -InputObject @(`$args) -Compress)
}
& '$($entry.Replace("'", "''"))' $quoted
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    $output=& pwsh -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
    @{exit=$LASTEXITCODE;output=($output | Out-String)}
}
foreach ($case in @(
    @{arguments=@('deploy');target='staging'},
    @{arguments=@('deploy','-Target','staging');target='staging'},
    @{arguments=@('deploy','-Target','production');target='production'}
)) {
    $result=Dispatch $case.arguments
    if ($result.exit -ne 0 -or $result.output -notmatch 'DISPATCH:(\[[^\r\n]+\])') { throw $result.output }
    $argv=$Matches[1] | ConvertFrom-Json
    if ($argv -notcontains "target=$($case.target)" -or $argv -notcontains 'operation=deploy') {
        throw "Deployment did not preserve the selected target: $($result.output)"
    }
}
foreach ($helpArgs in @(@(), @('help'), @('db','--help'), @('--help'))) {
    $helpResult=Dispatch $helpArgs
    if ($helpResult.exit -ne 0 -or $helpResult.output -match 'DISPATCH:' -or $helpResult.output -notmatch 'Laplace Operator & Developer CLI') {
        throw "Help did not print cheat sheet without dispatching: $($helpResult.output)"
    }
}
foreach ($dbCase in @(
    @('db','-Target','staging','-Database','substrate','-DatabaseOperation','status'),
    @('db','staging','substrate','status'),
    @('db','substrate','staging','status')
)) {
    $dbResult=Dispatch $dbCase
    if ($dbResult.exit -ne 0 -or $dbResult.output -notmatch 'DISPATCH:(\[[^\r\n]+\])') { throw $dbResult.output }
    $dbArgv=$Matches[1] | ConvertFrom-Json
    if ($dbArgv -notcontains 'db-ops.yml' -or $dbArgv -notcontains 'target=staging' -or $dbArgv -notcontains 'database=substrate' -or $dbArgv -notcontains 'operation=status') {
        throw "DB dispatch did not preserve target/database/operation: $($dbResult.output)"
    }
}
$rebuild=Dispatch @('components','-Target','staging','-Force')
if ($rebuild.exit -ne 0 -or $rebuild.output -notmatch 'DISPATCH:(\[[^\r\n]+\])') { throw $rebuild.output }
$rebuildArgv=$Matches[1] | ConvertFrom-Json
foreach ($required in 'laplace.yml','SaltyPatron/Laplace-Operations','rebuild_runtime=true','drop=false','reseed=false','cloud=false') {
    if ($rebuildArgv -notcontains $required) { throw "Native replacement dispatch missing $required" }
}
foreach ($arguments in @(
    @('deploy','-Target','production','-Check','operation-targets'),
    @('repair-postgres','-List'),
    @('storage','-List'),
    @('test','-Check',','),
    @('test','-Check','operation-targets','-SourcePath','C:\local-source'),
    @('test','-Check','operation-targets','-List'),
    @('components','-Target','production','-Force'),
    @('components','-Target','cloud','-Force'),
    @('build','-Target','production'),
    @('prepare','-Target','staging'),
    @('start','-Target','staging'),
    @('clients','-Target','staging'),
    @('restart-iis','-Target','staging'),
    @('db','-Target','production','-Database','substrate'),
    @('db','-Target','staging','-Database','both'),
    @('deploy','-Target','cloud'),
    @('verify','-Target','production','-SourcePath','C:\local-source')
)) {
    $result=Dispatch $arguments
    if ($result.exit -eq 0 -or $result.output -match 'DISPATCH:') { throw "Invalid target reached dispatch: $($arguments -join ' ')" }
}
$listed=Dispatch @('test','-List')
if ($listed.exit -ne 0 -or $listed.output -notmatch 'operation-targets' -or $listed.output -match 'DISPATCH:') { throw 'Registered tests are not discoverable through laplace-ops.' }
if($IsWindows){
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('laplace-operator-client-'+[guid]::NewGuid().ToString('N'))
    $savedLocal=$env:LOCALAPPDATA
    try{
        $bin=Join-Path $temporary 'Laplace/bin'
        $null=New-Item -ItemType Directory -Path $bin -Force
        @'
@echo off
if "%~2"=="--catalog" (
echo {"sources":[],"formats":[]}
exit /b 0
)
echo INSTALLED-INGEST: "%~1" "%~2" "%~3"
exit /b 23
'@ | Set-Content -LiteralPath (Join-Path $bin 'laplace.cmd') -Encoding ascii
        $env:LOCALAPPDATA=$temporary
        $catalog=& pwsh -NoProfile -File $entry sources desktop -Json
        if($LASTEXITCODE -or ($catalog|ConvertFrom-Json).sources.Count -ne 0){throw 'sources did not use the installed client catalog.'}
        $output=@(& pwsh -NoProfile -File $entry ingest desktop 'one source' two 2>&1)
        if($LASTEXITCODE -ne 23 -or ($output -join "`n") -notlike '*INSTALLED-INGEST: "ingest" "one source" "two"*'){
            throw "Installed ingestion arguments or failure exit were changed: $($output -join ' ')"
        }
    }finally{
        $env:LOCALAPPDATA=$savedLocal
        if([IO.Path]::GetDirectoryName($temporary) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')){throw 'Invalid operator fixture cleanup root.'}
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
'Operation targets: dispatch preserves staging/production; invalid local/remote combinations refused.'

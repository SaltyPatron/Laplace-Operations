#Requires -Version 7
# Check CLI dispatch only. Deployment evidence comes from the real GitHub run.
$ErrorActionPreference='Stop'
$entry=(Resolve-Path "$PSScriptRoot/../laplace.ps1").Path
function Dispatch([string[]]$Arguments) {
    $quoted=@($Arguments | ForEach-Object { if ($_ -in '-Target','-SourcePath','-Database','-DatabaseOperation','-Yes') { $_ } else { "'" + $_.Replace("'", "''") + "'" } }) -join ' '
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
foreach ($arguments in @(
    @('build','-Target','production'),
    @('prepare','-Target','staging'),
    @('start','-Target','staging'),
    @('restart-iis','-Target','staging'),
    @('db','-Target','production','-Database','substrate'),
    @('db','-Target','staging','-Database','both'),
    @('deploy','-Target','cloud'),
    @('verify','-Target','production','-SourcePath','C:\local-source')
)) {
    $result=Dispatch $arguments
    if ($result.exit -eq 0 -or $result.output -match 'DISPATCH:') { throw "Invalid target reached dispatch: $($arguments -join ' ')" }
}
'Operation targets: dispatch preserves staging/production; invalid local/remote combinations refused.'

#Requires -Version 7
# Check CLI dispatch only. Deployment evidence comes from the real GitHub run.
$ErrorActionPreference='Stop'
$entry=(Resolve-Path "$PSScriptRoot/../laplace.ps1").Path
function Dispatch([string[]]$Arguments) {
    $quoted=@($Arguments | ForEach-Object { if ($_ -in '-Target','-SourcePath') { $_ } else { "'" + $_.Replace("'", "''") + "'" } }) -join ' '
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
foreach ($arguments in @(
    @('build','-Target','production'),
    @('prepare','-Target','staging'),
    @('start','-Target','staging'),
    @('deploy','-Target','knowledge'),
    @('verify','-Target','production','-SourcePath','C:\local-source')
)) {
    $result=Dispatch $arguments
    if ($result.exit -eq 0 -or $result.output -match 'DISPATCH:') { throw "Invalid target reached dispatch: $($arguments -join ' ')" }
}
'Operation targets: dispatch preserves staging/production; invalid local/remote combinations refused.'

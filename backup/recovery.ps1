#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Target,
    [string]$Configuration = "$PSScriptRoot/recovery-installation.json"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
$targets = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable
if (-not $targets.ContainsKey($Target)) { throw "No application recovery installation declared for $Target" }
$targetConfig = $targets[$Target]
$hostName = $targetConfig.host
$runId = 'recovery-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$remote = $targetConfig['work-dir'].TrimEnd('/') + '/' + $runId
function Sh([string]$Value) { "'" + $Value.Replace("'", "'\''") + "'" }
& ssh -o BatchMode=yes $hostName ('sudo -n install -d -o "$(id -un)" -- ' + (Sh $remote))
if ($LASTEXITCODE) { throw 'Cannot create the declared recovery workspace with the host administrator identity.' }
& scp "$PSScriptRoot/restore-application.py" "${hostName}:$remote/restore-application.py"
if ($LASTEXITCODE) { throw 'Cannot transfer the application recovery implementation.' }
$remoteArguments = @('sudo','-n','python3',"$remote/restore-application.py")
foreach ($entry in $targetConfig.GetEnumerator()) {
    if ($entry.Key -eq 'host') { continue }
    $remoteArguments += '--' + $entry.Key
    $remoteArguments += [string]$entry.Value
}
$remoteArguments += @('--output', "$remote/receipt.json")
& ssh -o BatchMode=yes $hostName (($remoteArguments | ForEach-Object { Sh $_ }) -join ' ')
$operationExit = $LASTEXITCODE
$local = Join-Path $env:LAPLACE_WORK "operations/$runId"
[void](New-Item -ItemType Directory -Path $local -Force)
& scp "${hostName}:$remote/receipt.json" (Join-Path $local 'receipt.json')
$receiptExit = $LASTEXITCODE
if ($operationExit) { throw "Application recovery failed (exit $operationExit); remote evidence: $remote" }
if ($receiptExit) { throw "Recovery completed but its receipt could not be downloaded from $remote" }
$receipt = Get-Content -LiteralPath (Join-Path $local 'receipt.json') -Raw | ConvertFrom-Json
if (-not $receipt.passed -or -not $receipt.disposable_database_removed) { throw 'Recovery receipt did not pass including cleanup.' }
Write-Host "Application recovery verified; receipt: $local/receipt.json"

# Execute the backup's Windows paths, including repeat copies and failure propagation.
# Fixtures stay under TEMP for inspection; no service, task, network share or production data is changed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$fixture = Join-Path $env:TEMP ('laplace-backup-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'source'
$destination = Join-Path $fixture 'destination'
$env:LAPLACE_BACKUP_LOGS = Join-Path $fixture 'logs'
$env:LAPLACE_BACKUP_JOBS = Join-Path $fixture 'jobs.psd1'
$env:LAPLACE_TEST_SOURCE = $source
$env:LAPLACE_TEST_DEST = $destination
New-Item -ItemType Directory -Force $source,$destination,$env:LAPLACE_BACKUP_LOGS | Out-Null
@'
@{ Mounts=@{}; Sets=@(@{Name='test';Logs='';Inbox='%LAPLACE_TEST_DEST%';Patches=$false;Jobs=@(
@{n='files';s='%LAPLACE_TEST_SOURCE%';d='files';required=$true}
)}) }
'@ | Set-Content -LiteralPath $env:LAPLACE_BACKUP_JOBS
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Refuses([scriptblock]$operation, [string]$message) {
    $refused = $false
    try { & $operation } catch { $refused = $true }
    Assert $refused $message
}
'before' | Set-Content -LiteralPath (Join-Path $source 'example.txt')
'hidden source' | Set-Content -LiteralPath (Join-Path $source '.hidden')
[IO.File]::SetAttributes((Join-Path $source '.hidden'), [IO.FileAttributes]::Hidden)
. "$repo\backup\copyoff.ps1" -Set test -Plan | Out-Null
Assert ($jobs[0].s -eq $source) 'Machine path was not expanded'
Assert (-not (Test-Path "$logs\manifests")) 'Plan wrote backup directories'
Write-Output 'PASS: machine paths resolve; plan does not copy or create logs'

& pwsh.exe -NoProfile -File "$repo\backup\copyoff.ps1" -Set test -ManifestOnly > "$fixture\first.log"
Assert ($LASTEXITCODE -eq 0) 'First manifest failed'
$first = Get-FileHash "$logs\manifests\files.tsv"
New-Item -ItemType Directory -Force "$logs\done" | Out-Null
'old receipt' | Set-Content "$logs\done\files"
'after with new content' | Set-Content -LiteralPath (Join-Path $source 'example.txt')
& pwsh.exe -NoProfile -File "$repo\backup\copyoff.ps1" -Set test -ManifestOnly > "$fixture\second.log"
Assert ($LASTEXITCODE -eq 0) 'Second manifest failed'
Assert ((Get-FileHash "$logs\manifests\files.tsv").Hash -ne $first.Hash) 'Old done marker suppressed changed source'
Assert (-not (Test-Path "$logs\done\files")) 'Manifest-only run claimed a completed copy'
Write-Output 'PASS: changed source is hashed again despite an earlier done marker'

# Use actual Robocopy and actual SHA-256 readback with a local fixture. Only remote free-space probing is replaced.
New-Item -ItemType Directory -Force "$logs\robocopy" | Out-Null
function Assert-Room($job) { }
Copy-Job $jobs[0]
Test-CopiedManifest $jobs[0]
$copied = Join-Path $jobs[0].d 'example.txt'
Assert ((Get-Content $copied) -eq 'after with new content') 'Copy did not reach its destination'
Set-Content -LiteralPath $copied -Value 'corrupt'
Refuses { Test-CopiedManifest $jobs[0] } 'Corrupt destination passed verification'
Write-Output 'PASS: real Robocopy copy verifies; corrupt destination fails'

function robocopy.exe { $global:LASTEXITCODE = 8 }
Refuses { Copy-Job $jobs[0] } 'Robocopy failure was swallowed'
Remove-Item Function:robocopy.exe
Write-Output 'PASS: Robocopy failure propagates'

$lockedPath = Join-Path $source 'locked.txt'
[IO.File]::WriteAllText($lockedPath,'unreadable while open')
$locked = [IO.File]::Open($lockedPath,'Open','Read','None')
try {
    & pwsh.exe -NoProfile -File "$repo\backup\hash-manifest.ps1" -Root $source -Out "$fixture\locked.tsv" *> "$fixture\locked.log"
    Assert ($LASTEXITCODE -ne 0) 'Unreadable file was omitted with a success result'
    Assert (-not (Test-Path "$fixture\locked.tsv")) 'Incomplete hash manifest was published'
} finally { $locked.Dispose() }
Write-Output 'PASS: unreadable source fails without publishing a partial manifest'

$env:LAPLACE_TEST_SOURCE = Join-Path $fixture 'missing'
& pwsh.exe -NoProfile -File "$repo\backup\run.ps1" *> "$fixture\runner.log"
Assert ($LASTEXITCODE -ne 0) 'Task runner reported success after a missing required source'
Write-Output 'PASS: missing required source reaches the task runner as a failure'
"Backup regression checks passed. Evidence: $fixture"

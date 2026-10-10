#Requires -Version 7
# The whole copy-off, set by set in jobs.psd1's order, so the sets do not share the 1 GbE link.
# Run by the scheduled task setup.ps1 backup declares (LAPLACE_BACKUP_TASK), so it outlives the session that starts it:
#   Start-ScheduledTask -TaskName copyoff
# Its pid goes to run.pid; each set's output to run.log (D) or run-<set>.log under LAPLACE_BACKUP_LOGS.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\laplace.env.ps1"
. "$PSScriptRoot\config.ps1"
$logs = $env:LAPLACE_BACKUP_LOGS
New-Item -ItemType Directory -Force $logs | Out-Null
$PID | Set-Content (Join-Path $logs 'run.pid')
foreach ($s in (Read-BackupConfiguration $env:LAPLACE_BACKUP_JOBS).Sets) {
    $log = Join-Path $logs $(if ($s.Name -eq 'D') { 'run.log' } else { "run-$($s.Name.ToLowerInvariant()).log" })
    & pwsh.exe -NoProfile -File "$PSScriptRoot\copyoff.ps1" -Set $s.Name *>&1 | Tee-Object -FilePath $log
    $result = $LASTEXITCODE
    "$($s.Name): finished, exit $result  $(Get-Date -Format s)" | Tee-Object -FilePath $log -Append
    if ($result -ne 0) { exit $result }
}
exit 0

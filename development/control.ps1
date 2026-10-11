#Requires -Version 7
[CmdletBinding()]
param([ValidateSet('start','stop','status','logs')][string]$Operation='status', [string]$SourcePath,
    [string]$Installation=$(if ($env:LAPLACE_DEVELOPMENT_INSTALLATION) {$env:LAPLACE_DEVELOPMENT_INSTALLATION} else {"$PSScriptRoot/installation.json"}))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
if (-not $SourcePath) { $SourcePath=Join-Path $env:LAPLACE_SRC 'Laplace' }
$SourcePath=(Resolve-Path -LiteralPath $SourcePath).Path
$Installation=(Resolve-Path -LiteralPath $Installation).Path
$config=Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
$port=if ($env:LAPLACE_API_PORT) {[int]$env:LAPLACE_API_PORT} else {[int]$config.api_port}
if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid development API port.' }
$operations=Join-Path $env:LAPLACE_WORK 'operations'

function ActiveRun {
    if (-not (Test-Path -LiteralPath $operations)) { return }
    foreach ($directory in Get-ChildItem -LiteralPath $operations -Directory -Filter 'desktop-run-*' | Sort-Object LastWriteTime -Descending) {
        $file=Join-Path $directory.FullName 'receipt.json'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try { $record=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { continue }
        if ($record.status -ne 'running' -or $record.source -ne $SourcePath -or $record.base_url -ne "http://localhost:$port") { continue }
        if (-not $record.process_id -or -not $record.process_started_utc -or -not $record.api_path) { continue }
        $process=Get-Process -Id $record.process_id -ErrorAction SilentlyContinue
        if (-not $process -or $process.ProcessName -ne 'dotnet' -or
            $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$record.process_started_utc).UtcTicks) { continue }
        $details=Get-CimInstance Win32_Process -Filter "ProcessId=$($record.process_id)"
        # Match the complete application argument, not just a process name or a
        # recycled PID. A stale receipt never authorizes a stop of another app.
        $escaped=[regex]::Escape($record.api_path)
        if ($details.CommandLine -notmatch "(?:^|\s)`"?$escaped`"?\s*$") { continue }
        return [pscustomobject]@{record=$record;directory=$directory.FullName;process=$process}
    }
}

$lockName='Local\LaplaceDevelopment-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$operations|$port")))
$mutex=[Threading.Mutex]::new($false,$lockName)
$locked=$false
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another desktop lifecycle operation is in progress.' }
    $active=ActiveRun
    switch ($Operation) {
        'start' {
            if ($active) { Write-Host "Laplace is already running: $($active.record.base_url)"; break }
            $runId=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
            $work=Join-Path $operations "desktop-run-$runId"
            [void](New-Item -ItemType Directory -Path $work -Force)
            $arguments=@('-NoProfile','-File',"$PSScriptRoot/background.ps1",'-SourcePath',$SourcePath,'-Installation',$Installation,'-RunId',$runId)
            # Shell launch detaches inherited automation pipes. The supervisor
            # writes its own log; redirecting handles here keeps callers open.
            $supervisor=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @($arguments | ForEach-Object {'"'+$_+'"'}) `
                -WorkingDirectory $SourcePath -WindowStyle Hidden -PassThru
            try {
                $deadline=[DateTime]::UtcNow.AddSeconds(180)
                do {
                    if ($supervisor.HasExited) { throw "Desktop startup failed. Inspect $work/launcher.log and $work/api.stderr.log." }
                    $active=ActiveRun
                    if ($active -and $active.directory -eq $work) { break }
                    Start-Sleep -Milliseconds 250
                } while ([DateTime]::UtcNow -lt $deadline)
                if (-not $active -or $active.directory -ne $work) { throw "Desktop readiness timed out. Inspect $work." }
            } catch {
                # This Process object belongs to this invocation, never to a PID
                # read from disk. A failed start must not leave a hidden listener.
                if (-not $supervisor.HasExited) { $supervisor.Kill($true); $supervisor.WaitForExit() }
                throw
            }
            Write-Host "Laplace is ready: $($active.record.base_url)"
            Write-Host 'Use ./laplace.ps1 stop -Target desktop to stop it.'
        }
        'stop' {
            if (-not $active) { Write-Host 'No owned desktop instance is running.'; break }
            if ($active.record.control_version -ne 1) { throw 'This process predates desktop lifecycle controls; stop its original launcher.' }
            [IO.File]::WriteAllText((Join-Path $active.directory 'stop.request'),[DateTime]::UtcNow.ToString('o'))
            if (-not $active.process.WaitForExit(10000)) { throw 'The desktop launcher has not completed its stop request; inspect its logs.' }
            Write-Host "Stopped Laplace at $($active.record.base_url)."
            $active=$null
        }
        'logs' {
            if (-not $active) { throw 'No owned desktop instance is running. Startup failures are under LAPLACE_WORK/operations/desktop-run-*.' }
            Write-Host "Logs: $($active.directory)"
            Get-Content -LiteralPath (Join-Path $active.directory 'api.stdout.log') -Tail 40
            Get-Content -LiteralPath (Join-Path $active.directory 'api.stderr.log') -Tail 20
        }
    }
    if ($active) {
        [ordered]@{status='running';url=$active.record.base_url;pid=$active.record.process_id;revision=$active.record.revision;
            source=$active.record.source;logs=$active.directory} | ConvertTo-Json
    } elseif ($Operation -eq 'status') { @{status='stopped';url="http://localhost:$port"} | ConvertTo-Json }
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }

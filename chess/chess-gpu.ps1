#Requires -Version 7
<#
  The RTX 4060 Ti's two modes on HART-DESKTOP, switched explicitly and without elevation.

    pwsh -File chess-gpu.ps1 status    the three embedding services, the card's free memory, any Lc0 running
    pwsh -File chess-gpu.ps1 on        chess-GPU mode: the embedders stopped, the card free for Lc0
    pwsh -File chess-gpu.ps1 off       index mode (the default): the embedders started and healthy on 8711-8713

  Index mode is the machine's default: the services start automatically, so a reboot always comes back to it, and
  code search needs it. Chess-GPU mode exists because Lc0 and the llama.cpp embedders cannot share 8 GB, and an Lc0
  whose speed depends on whatever code search is doing is not a ruler. Lc0 is never a service: the conductor
  (fastchess, cutechess) starts it per match, and only in chess-GPU mode.

  The operator may start, stop and query these services from a normal shell because each service's DACL carries one
  ACE for the operator (RP start, WP stop, LC query, LO interrogate), applied once, elevated, by
  D:\Logs\grant-gpu-services.ps1. sc.exe is used rather than Stop-Service: .NET's ServiceController enumerates
  dependents, which needs a right (DT) the ACE does not give.

  Every switch appends a line to $LAPLACE_WORK\logs\chess-gpu.tsv (time, mode, free MiB, driver), which a match
  generation's receipt names. llama-generative stays Disabled and is not touched.
#>
param([Parameter(Position = 0)][ValidateSet('on', 'off', 'status')][string]$Mode = 'status',
      [int]$NeedFreeMiB = 6000, [int]$TimeoutSec = 120)
$ErrorActionPreference = 'Stop'
$services = 'llama-embedding', 'llama-embedding-text', 'llama-reranker'
$ports = 8711, 8712, 8713
. "$PSScriptRoot\..\laplace.env.ps1"
$work = $env:LAPLACE_WORK
$journal = Join-Path $work 'logs\chess-gpu.tsv'

function Gpu { $q = (& nvidia-smi --query-gpu=memory.free,memory.used,driver_version,name --format=csv,noheader,nounits) -split ',\s*'
               [pscustomobject]@{ free = [int]$q[0]; used = [int]$q[1]; driver = $q[2]; name = $q[3] } }
function State([string]$s) { $line = (sc.exe query $s | Select-String 'STATE'); if (-not $line) { 'MISSING' } else { ($line.ToString() -replace '.*:\s+\d+\s+', '').Trim() } }
function Healthy([int]$port) { try { (Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { $false } }
function WaitUntil([scriptblock]$cond, [string]$what) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $cond)) { if ($t.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "timed out after $TimeoutSec s waiting for $what" }; Start-Sleep -Milliseconds 500 }
}
function Record([string]$mode) {
    $g = Gpu; New-Item -ItemType Directory -Force (Split-Path $journal) | Out-Null
    if (-not (Test-Path $journal)) { "time`tmode`tfree_mib`tused_mib`tdriver`tgpu" | Set-Content $journal }
    "{0:yyyy-MM-ddTHH:mm:ssZ}`t$mode`t$($g.free)`t$($g.used)`t$($g.driver)`t$($g.name)" -f (Get-Date).ToUniversalTime() | Add-Content $journal
    $g
}

switch ($Mode) {
    'on' {
        foreach ($s in $services) { if ((State $s) -ne 'STOPPED') { $r = sc.exe stop $s; if ($LASTEXITCODE -and $LASTEXITCODE -ne 1062) { throw "sc.exe stop $s exited ${LASTEXITCODE}: $($r -join ' ')" } } }
        WaitUntil { @($services | Where-Object { (State $_) -ne 'STOPPED' }).Count -eq 0 } 'the embedding services to stop'
        WaitUntil { -not (Get-Process llama-server -ErrorAction SilentlyContinue) } 'llama-server to exit'
        WaitUntil { (Gpu).free -ge $NeedFreeMiB } "$NeedFreeMiB MiB free on the card"
        $g = Record 'chess-gpu'
        "chess-GPU mode: $($g.free) MiB free of $($g.free + $($g.used)) on $($g.name), driver $($g.driver); code search is unavailable until 'off'"
    }
    'off' {
        $lc0 = Get-Process lc0 -ErrorAction SilentlyContinue
        if ($lc0) { throw "Lc0 is running (pid $($lc0.Id -join ', ')); end the match first" }
        foreach ($s in $services) { if ((State $s) -ne 'RUNNING') { $r = sc.exe start $s; if ($LASTEXITCODE -and $LASTEXITCODE -ne 1056) { throw "sc.exe start $s exited ${LASTEXITCODE}: $($r -join ' ')" } } }
        foreach ($p in $ports) { WaitUntil { Healthy $p } "port $p /health" }
        $g = Record 'index'
        "index mode: embedders healthy on $($ports -join ', '); $($g.free) MiB free"
    }
    'status' {
        foreach ($s in $services) { '{0,-22} {1}' -f $s, (State $s) }
        foreach ($p in $ports) { '{0,-22} {1}' -f "port $p /health", $(if (Healthy $p) { 'ok' } else { 'no answer' }) }
        $g = Gpu; '{0,-22} {1} MiB free, {2} MiB used ({3}, driver {4})' -f 'gpu', $g.free, $g.used, $g.name, $g.driver
        $lc0 = Get-Process lc0 -ErrorAction SilentlyContinue; '{0,-22} {1}' -f 'lc0', $(if ($lc0) { "running, pid $($lc0.Id -join ', ')" } else { 'not running' })
        $now = if (@($services | Where-Object { (State $_) -eq 'RUNNING' }).Count -eq $services.Count) { 'index' } elseif (@($services | Where-Object { (State $_) -ne 'STOPPED' }).Count -eq 0) { 'chess-gpu' } else { 'mixed' }
        '{0,-22} {1}' -f 'mode', $now
    }
}

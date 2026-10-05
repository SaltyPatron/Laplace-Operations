#Requires -Version 7
<#
  The server's settings on the Windows machine, converged and checked: the counterpart of tune-pg.sh. TuneDeclared is
  the set. setup.ps1 settings is this same set when a person runs it elevated; a deployment runs this as the role (the
  role is superuser, so ALTER SYSTEM needs no elevation) and a drift fails the run. A setting that needs a restart is
  restarted only when this user may restart the service and no ingest holds its lock.

    pwsh -File tune-pg.ps1            apply what differs, reload, restart when allowed, check
    pwsh -File tune-pg.ps1 -Check     report drift, change nothing

  The values follow the machine, as on Linux: memory, cores and drives are read here; what the machine cannot say
  (what its other residents keep, the shared memory this Windows build maps, the log's room on a shared drive) is
  laplace.env.ps1's, with the measurement that set it. The two machines differ in every one of these (hart-server:
  12 threads, 128 GB, dedicated volumes; HART-DESKTOP: 32 threads, 48 GB with 34 held by other services, one shared
  drive), and the same rules give each its own numbers.
#>
param([switch]$Check)
if (-not $env:LAPLACE_PGDATA) { . "$PSScriptRoot\laplace.env.ps1" }
$TunePsqlExe = Join-Path $env:LAPLACE_PG_DIR 'bin\psql.exe'
$TuneConn = $env:LAPLACE_CONNINFO -replace 'dbname=\S+', 'dbname=postgres'
if ($TuneConn -notmatch 'dbname=') { $TuneConn += ' dbname=postgres' }

function TuneMB([string]$size) {
    if ($size -notmatch '^\s*(\d+)\s*(GB|MB|kB|KB|B)?\s*$') { throw "not a size: '$size'" }
    $n = [int64]$Matches[1]
    switch ($Matches[2]) { 'GB' { $n * 1024 } 'MB' { $n } { $_ -in 'kB', 'KB' } { [int64]($n / 1024) } default { [int64]($n / 1048576) } }
}
function TuneDrive([string]$path) { ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path))).Substring(0, 1).ToUpperInvariant() }

# Every setting, derived from the machine and the installation's declarations. The reasons are tune-pg.sh's: the log's
# bound is a checkpoint target, not a quota, so half a dedicated drive; wal_compression zstd measured against lz4;
# wal_level minimal because nothing reads this server's log but its own recovery, and it will not start at minimal
# unless max_wal_senders is 0. Windows: huge pages off (the backends' shared-memory mapping failed at 4 GB before any
# large page was tried; LAPLACE_PG_BUFFERS_MAX), io_method worker (no io_uring), the server's own log under the work
# tree (no journal).
function TuneDeclared {
    $ramMB   = [int64]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    $cores   = [int](Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    $usable  = [math]::Max($ramMB - (TuneMB $env:LAPLACE_PG_RESERVED), [int64]($ramMB / 8))   # what the server may use
    $buffers = [math]::Min([int64]($usable / 4), (TuneMB $env:LAPLACE_PG_BUFFERS_MAX))
    $wal     = if ((TuneDrive $env:LAPLACE_PGWAL) -ne (TuneDrive $env:LAPLACE_PGDATA)) { $d = Get-PSDrive (TuneDrive $env:LAPLACE_PGWAL); [int64](($d.Used + $d.Free) / 1MB / 2) }
               else { TuneMB $env:LAPLACE_PGWAL_ROOM }
    $logs    = (Join-Path $env:LAPLACE_WORK 'logs\postgres') -replace '\\', '/'
    $s = [ordered]@{
        wal_level                        = 'minimal'
        max_wal_senders                  = '0'
        shared_buffers                   = "${buffers}MB"
        effective_cache_size             = "$([int64]($usable * 7 / 10))MB"
        work_mem                         = '256MB'
        maintenance_work_mem             = "$([math]::Min(8192, [int64]($usable / 4)))MB"
        huge_pages                       = 'off'
        io_method                        = 'worker'
        io_workers                       = "$([int]($cores * 2 / 3))"
        effective_io_concurrency         = '256'
        maintenance_io_concurrency       = '256'
        random_page_cost                 = '1.1'
        default_toast_compression        = 'lz4'
        max_wal_size                     = "${wal}MB"
        max_slot_wal_keep_size           = "${wal}MB"
        min_wal_size                     = '4GB'
        wal_buffers                      = '256MB'
        wal_compression                  = 'zstd'
        checkpoint_timeout               = '60min'
        checkpoint_completion_target     = '0.9'
        bgwriter_lru_maxpages            = '1000'
        max_worker_processes             = "$($cores + 4)"
        max_parallel_workers             = "$cores"
        max_parallel_workers_per_gather  = "$([int]($cores / 2))"
        max_parallel_maintenance_workers = "$([int]($cores / 2))"
        jit                              = 'off'
        enable_parallel_append           = 'on'
        gin_pending_list_limit           = '32MB'
        autovacuum_max_workers           = "$([math]::Max(3, [int]($cores / 2)))"
        autovacuum_naptime               = '10s'
        autovacuum_vacuum_cost_delay     = '0'
        autovacuum_vacuum_cost_limit     = '2000'
        autovacuum_vacuum_scale_factor   = '0.05'
        autovacuum_analyze_scale_factor  = '0.02'
        autovacuum_vacuum_insert_scale_factor = '0.01'
        autovacuum_work_mem              = '1GB'
        shared_preload_libraries         = 'pg_stat_statements,auto_explain'
        'pg_stat_statements.track'       = 'all'
        'auto_explain.log_min_duration'  = '5s'
        track_io_timing                  = 'on'
        track_wal_io_timing              = 'on'
        logging_collector                = 'on'
        log_directory                    = $logs
        log_filename                     = 'postgresql-%Y-%m-%d.log'
        log_rotation_age                 = '1d'
        log_rotation_size                = '0'
        log_min_messages                 = 'warning'
        log_checkpoints                  = 'on'
        listen_addresses                 = '*'
        ssl                              = $(if (Test-Path (Join-Path $env:LAPLACE_PGDATA 'server.crt')) { 'on' } else { 'off' })
        port                             = '5432'
        max_connections                  = '100'
        max_prepared_transactions        = '32'
    }
    if ($env:LAPLACE_PGTEMP) { $s['temp_tablespaces'] = 'pgtemp' }
    $s
}

# an ingest of the database laplace.env.ps1 names holds its lock open (no sharing) while it runs
function TuneIngesting {
    $db = if ($env:LAPLACE_CONNINFO -match 'dbname=(\S+)') { $Matches[1] } else { 'default' }
    $l = Join-Path $env:LAPLACE_LOCKS "ingest-$db.lock"
    if (-not (Test-Path $l)) { return $false }
    try { $fs = [IO.File]::Open($l, 'Open', 'ReadWrite', 'None'); $fs.Close(); $false } catch { $true }
}

function TunePsql([string]$sql) {
    $f = [IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $f -Value $sql -Encoding utf8
        $out = & $TunePsqlExe -X $TuneConn -v ON_ERROR_STOP=1 -At -F '|' -f $f 2>&1
        if ($LASTEXITCODE) { throw "psql: $($out -join ' ')" }
        $out
    } finally { Remove-Item $f -ErrorAction SilentlyContinue }
}

# name|match|context|source|pending|live, for every declared setting: the server itself compares, unit by unit.
# match is the value only; pending is separate, so a value already in force is not written again because a restart
# is owed. The same statement as tune-pg.sh's.
function TuneReportSql {
    $d = TuneDeclared
    $vals = ($d.Keys | ForEach-Object { "('{0}','{1}')" -f $_, ($d[$_] -replace "'", "''") }) -join ','
    @"
WITH want(name, value) AS (VALUES $vals),
p AS (
  SELECT w.name, w.value,
         substring(w.value from '^(-?[0-9.]+)')::numeric AS n,
         nullif(substring(lower(w.value) from '[a-z]+`$'), '') AS u
  FROM want w
)
SELECT w.name,
       CASE
         WHEN s.name IS NULL THEN 'f'
         WHEN s.vartype = 'bool' THEN
           CASE WHEN current_setting(w.name) =
             CASE lower(w.value) WHEN 'on' THEN 'on' WHEN 'true' THEN 'on' WHEN '1' THEN 'on' WHEN 'yes' THEN 'on'
                                 WHEN 'off' THEN 'off' WHEN 'false' THEN 'off' WHEN '0' THEN 'off' WHEN 'no' THEN 'off'
                                 ELSE w.value END
           THEN 't' ELSE 'f' END
         WHEN s.vartype IN ('integer', 'real') AND coalesce(s.unit, '') = '' THEN
           CASE WHEN abs(s.setting::numeric - p.n) < 0.0000001 THEN 't' ELSE 'f' END
         WHEN s.vartype IN ('integer', 'real') AND s.unit ~ 'B`$' THEN
           CASE WHEN s.setting::numeric = round(pg_size_bytes(w.value)::numeric
              / pg_size_bytes(CASE WHEN s.unit ~ '^[0-9]' THEN s.unit ELSE '1 ' || s.unit END)) THEN 't' ELSE 'f' END
         WHEN s.vartype IN ('integer', 'real') AND s.unit IN ('us','ms','s','min','h','d') THEN
           CASE WHEN s.setting::numeric * CASE s.unit WHEN 'us' THEN 0.001 WHEN 'ms' THEN 1 WHEN 's' THEN 1000 WHEN 'min' THEN 60000 WHEN 'h' THEN 3600000 WHEN 'd' THEN 86400000 END
                     = p.n * CASE coalesce(p.u, s.unit) WHEN 'us' THEN 0.001 WHEN 'ms' THEN 1 WHEN 's' THEN 1000 WHEN 'min' THEN 60000 WHEN 'h' THEN 3600000 WHEN 'd' THEN 86400000 END
           THEN 't' ELSE 'f' END
         ELSE
           CASE WHEN replace(current_setting(w.name), ' ', '') = replace(w.value, ' ', '') THEN 't' ELSE 'f' END
       END,
       coalesce(s.context, ''),
       coalesce(s.source, ''),
       CASE WHEN s.pending_restart THEN 't' ELSE 'f' END,
       coalesce(current_setting(w.name, true), '')
FROM want w
LEFT JOIN pg_settings s ON s.name = w.name
LEFT JOIN p ON p.name = w.name
ORDER BY 1;
"@
}
function TuneReport { foreach ($line in (TunePsql (TuneReportSql))) { if (-not $line) { continue }; $f = $line -split '\|'; [pscustomobject]@{ name = $f[0]; match = $f[1]; context = $f[2]; source = $f[3]; pending = $f[4]; live = $f[5] } } }

function TuneApply {
    $want = TuneDeclared; $n = 0
    foreach ($r in TuneReport) {
        # already the declared value and already recorded, or a postmaster knob already in force: writing that again
        # can mark a restart for a value the server is already running
        if ($r.match -eq 't' -and ($r.source -eq 'configuration file' -or $r.context -eq 'postmaster')) { continue }
        $v = $want[$r.name]
        TunePsql "ALTER SYSTEM SET $($r.name) = '$($v -replace "'", "''")'" | Out-Null
        "tune-pg: set $($r.name) = $v"; $n++
    }
    if ($n) {
        TunePsql 'SELECT pg_reload_conf()' | Out-Null
        # the reload is a signal the postmaster handles on its own time (on Windows, later than on Linux): wait until every
        # setting just written is either in force or marked pending a restart, so the restart and the check read the truth
        foreach ($i in 1..20) { Start-Sleep -Milliseconds 500; $r = @(TuneReport | Where-Object { $_.match -ne 't' -and $_.pending -ne 't' }); if (-not $r.Count) { break } }
    }
    "tune-pg: $($want.Count) declared, $n set"
}

function TuneRestart {
    # pending_restart is a flag of the backend that handled the reload; on this Windows build a new connection never shows
    # it. A postmaster setting that does not match is a restart owed, flag or no flag.
    $pending = (@(TuneReport | Where-Object { $_.pending -eq 't' -or ($_.match -ne 't' -and $_.context -eq 'postmaster') } | ForEach-Object name) -join ', ')
    if (-not $pending) { return $true }
    if (TuneIngesting) { Write-Warning "tune-pg: restart for $pending DEFERRED: an ingest is running"; return $false }
    $svc = Get-Service -Name $env:LAPLACE_PGSERVICE -ErrorAction SilentlyContinue
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $svc -or -not $admin) { Write-Warning "tune-pg: $pending pending_restart; $env:LAPLACE_PGSERVICE was not restarted (elevated: setup.ps1 settings)"; return $false }
    $began = (TunePsql 'SELECT pg_postmaster_start_time()') -join ''
    Restart-Service -Name $env:LAPLACE_PGSERVICE -Force
    foreach ($i in 1..180) {
        Start-Sleep -Seconds 1
        try { $now = (TunePsql 'SELECT pg_postmaster_start_time()') -join '' } catch { continue }
        if ($now -and $now -ne $began) { "tune-pg: $env:LAPLACE_PGSERVICE restarted for $pending"; return $true }
    }
    Write-Warning "tune-pg: $env:LAPLACE_PGSERVICE was not restarted within 180 s"; $false
}

function TuneCheck {
    $want = TuneDeclared; $bad = 0; $n = 0
    foreach ($r in TuneReport) {
        $n++
        if ($r.match -ne 't' -or $r.pending -eq 't') { Write-Warning "tune-pg: $($r.name) = '$($r.live)' declared '$($want[$r.name])' source=$($r.source) pending=$($r.pending)"; $bad++ }
    }
    if ($n -ne $want.Count) { Write-Warning "tune-pg: $n of $($want.Count) settings read"; return $false }
    if ($bad) { return $false }
    "tune-pg: $n settings match"; $true
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Check) { if (TuneCheck) { exit 0 } else { exit 1 } }
    TuneApply
    TuneRestart | Out-Null
    if (-not (TuneCheck)) { exit 1 }
}

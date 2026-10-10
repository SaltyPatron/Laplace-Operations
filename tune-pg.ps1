#Requires -Version 7
<#
  The server's settings on the Windows machine, derived from the machine that runs it, converged and checked: the
  counterpart of tune-pg.sh, the same rules. TuneDeclared is the set. setup.ps1 settings is this same set when a person
  runs it elevated; a deployment runs this as the role (the role is superuser, so ALTER SYSTEM needs no elevation) and a
  drift fails the run. A setting that needs a restart is restarted only when this user may restart the service and no
  ingest holds its lock.

    pwsh -File tune-pg.ps1            apply what differs, reload, restart when allowed, check
    pwsh -File tune-pg.ps1 -Check     report drift, change nothing
    pwsh -File tune-pg.ps1 -Plan      the facts read from this machine and every setting they give; no connection

  The facts are read, not declared: the memory, the logical processors and the physical cores they sit on, the drive
  holding the write-ahead log and whether it is the log's own, whether the data's disk rotates. What the machine
  cannot say is laplace.env.ps1's, each with the measurement that set it: LAPLACE_PG_RESERVED (what its other
  residents keep: the llama-server services), LAPLACE_PG_BUFFERS_MAX (the largest shared memory this Windows build
  maps in every backend), LAPLACE_PG_PROFILE (knowledge or app: the connection plan). The memory is tune-pg.sh's one
  equation in four domains: of what the server may use, a quarter the shared cache, a quarter the backends' private
  memory (divided by the backends the plan allows), a quarter the client's, a quarter the page cache. Windows: huge
  pages off (the backends' shared-memory mapping failed at 4 GB before any large page was tried), io_method worker
  (no io_uring), the server's own log under the work tree (no journal).
#>
param([switch]$Check, [switch]$Plan)
if (-not $env:LAPLACE_PGDATA -or -not $env:LAPLACE_PGPORT) { . "$PSScriptRoot\laplace.env.ps1" }
$TunePsqlExe = Join-Path $env:LAPLACE_PG_DIR 'bin\psql.exe'
$TuneConn = $env:LAPLACE_CONNINFO -replace 'dbname=\S+', 'dbname=postgres'
if ($TuneConn -notmatch 'dbname=') { $TuneConn += ' dbname=postgres' }
$TuneProfile = if ($env:LAPLACE_PG_PROFILE) { $env:LAPLACE_PG_PROFILE } else { 'knowledge' }
if ($TuneProfile -notin 'knowledge', 'app') { throw "tune-pg: LAPLACE_PG_PROFILE is knowledge or app, not '$TuneProfile'" }

function TuneKB([string]$size) {   # a size with a unit (34GB, 512MB, 1048576kB, 4096) in kB
    if ($size -notmatch '^\s*(\d+)\s*(TB|GB|MB|kB|KB|B)?\s*$') { throw "not a size: '$size'" }
    $n = [int64]$Matches[1]
    switch ($Matches[2]) { 'TB' { $n * 1073741824 } 'GB' { $n * 1048576 } 'MB' { $n * 1024 } { $_ -in 'kB', 'KB' } { $n } 'B' { [int64]($n / 1024) } default { $n } }
}
function TuneDrive([string]$path) { ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path))).Substring(0, 1).ToUpperInvariant() }

# ---------------------------------------------------------------------------------------------------- the facts
# Each read from this machine; TUNE_FACT_* names one instead (-Plan for another machine, and the tests).
function TuneFactRamKB { if ($env:TUNE_FACT_RAM_KB) { return [int64]$env:TUNE_FACT_RAM_KB }; [int64]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1KB) }
function TuneFactThreads { if ($env:TUNE_FACT_THREADS) { return [int]$env:TUNE_FACT_THREADS }; [int](Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum }
function TuneFactCores { if ($env:TUNE_FACT_CORES) { return [int]$env:TUNE_FACT_CORES }; [int](Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum }
function TuneFactRotational {   # does the disk under the data rotate (MediaType HDD); unknown media does not
    if ($null -ne $env:TUNE_FACT_ROTATIONAL -and $env:TUNE_FACT_ROTATIONAL -ne '') { return [int]$env:TUNE_FACT_ROTATIONAL }
    try {
        $disk = Get-Partition -DriveLetter (TuneDrive $env:LAPLACE_PGDATA) -ErrorAction Stop | Select-Object -First 1 -ExpandProperty DiskNumber
        $media = (Get-PhysicalDisk -ErrorAction Stop | Where-Object DeviceId -eq $disk | Select-Object -First 1).MediaType
        if ($media -eq 'HDD') { 1 } else { 0 }
    } catch { 0 }
}
function TuneFactWal {   # the drive the log is on, and whether the log has it to itself: bytes, shared
    if ($env:TUNE_FACT_WAL_BYTES) { return @([int64]$env:TUNE_FACT_WAL_BYTES, [int]$(if ($env:TUNE_FACT_WAL_SHARED) { $env:TUNE_FACT_WAL_SHARED } else { 0 })) }
    $d = Get-PSDrive (TuneDrive $env:LAPLACE_PGWAL)
    $bytes = [int64]($d.Used + $d.Free)
    # A different drive can still hold builds, dependencies and other data. Only an
    # explicit machine declaration may spend half a drive on WAL; default to shared.
    $shared = 1
    switch ($env:LAPLACE_PG_WAL_DEDICATED) {
        { $_ -in $null, '', '0' } { }
        '1' {
            if ((TuneDrive $env:LAPLACE_PGWAL) -eq (TuneDrive $env:LAPLACE_PGDATA)) {
                throw 'tune-pg: a dedicated WAL drive cannot also hold PGDATA'
            }
            $shared = 0
        }
        default { throw 'tune-pg: LAPLACE_PG_WAL_DEDICATED must be 0 or 1' }
    }
    @($bytes, $shared)
}
function TuneFactReservedKB { if ($env:LAPLACE_PG_RESERVED) { TuneKB $env:LAPLACE_PG_RESERVED } else { [int64]0 } }
function TuneFactBuffersMaxKB { if ($env:LAPLACE_PG_BUFFERS_MAX) { TuneKB $env:LAPLACE_PG_BUFFERS_MAX } else { [int64]0 } }

# ---------------------------------------------------------------------------------------------------- the rules
function TunePlan {   # every derived quantity, tune-pg.sh's plan(): the same names, the same arithmetic (integers)
    $ramKB = TuneFactRamKB; $threads = TuneFactThreads; $cores = TuneFactCores; $reservedKB = TuneFactReservedKB; $capKB = TuneFactBuffersMaxKB
    $rotational = TuneFactRotational; $wal = TuneFactWal; $walBytes = $wal[0]; $shared = $wal[1]
    if ($cores -lt 1) { $cores = 1 }; if ($threads -lt $cores) { $threads = $cores }
    $usableKB = [math]::Max($ramKB - $reservedKB, [int64]($ramKB / 8))
    $sharedKB = [int64]($usableKB / 4); if ($capKB -gt 0) { $sharedKB = [math]::Min($sharedKB, $capKB) }; $sharedKB = [math]::Max($sharedKB, 131072)
    $ecsKB = [int64]($usableKB * 7 / 10)
    $privateKB = [int64]($usableKB / 4)
    $walMB = if ($shared -eq 1) { [math]::Min([int64]($walBytes / 1MB / 4), 32768) } else { [int64]($walBytes / 1MB / 2) }
    $walMB = [math]::Max($walMB, 1024)
    $minWalMB = [math]::Min([math]::Max([int64]($walMB / 8), 80), 4096)
    $walBufKB = [math]::Min([math]::Max([int64]($sharedKB / 32), 16384), [int64]($walMB * 1024 / 16))
    $par = $cores; $gather = [int]($cores / 2); $avw = [math]::Max(3, [int]($cores / 2)); $iow = [math]::Min([math]::Max([int]($threads * 2 / 3), 1), 32); $mwp = $par + 4
    $declaredServing = if ($env:LAPLACE_PG_SERVING) { [int]$env:LAPLACE_PG_SERVING } else { 0 }
    switch ($TuneProfile) {
        'knowledge' { $ingest = 1 + 2 * $cores + 3; $serving = if ($declaredServing) { $declaredServing } else { 4 * $threads }; $locks = 1024 }
        'app'       { $ingest = 0; $serving = if ($declaredServing) { $declaredServing } else { [math]::Max(16, 8 * $threads) }; $locks = 64 }
    }
    $reservedConns = 3; $conns = $ingest + $serving + $avw + $reservedConns
    $maintDomKB = [int64]($privateKB / 4); $mwmKB = [math]::Max([int64]($maintDomKB / 2), 65536); $avwmKB = [math]::Max([int64]($maintDomKB / 2 / $avw), 1024)
    $execKB = $privateKB - $maintDomKB; $backends = $conns + $par; $perKB = [int64]($execKB / $backends)
    $workKB = [math]::Max([int64]($perKB / 2), 4096); $tempKB = [math]::Max([int64]($perKB / 2), 8192)
    $overKB = [math]::Max([int64]($backends * ($workKB + $tempKB) + $mwmKB + $avw * $avwmKB - $privateKB), 0)
    if ($rotational -eq 1) { $eic = 2; $rpc = '4' } else { $eic = $iow; $rpc = '1.1' }
    [ordered]@{
        'fact.memory_kb' = $ramKB; 'fact.reserved_kb' = $reservedKB; 'fact.threads' = $threads; 'fact.cores' = $cores
        'fact.wal_volume_bytes' = $walBytes; 'fact.wal_volume_shared' = $shared; 'fact.data_rotational' = $rotational; 'fact.profile' = $TuneProfile
        usable_kb = $usableKB; shared_kb = $sharedKB; ecs_kb = $ecsKB; private_kb = $privateKB; wal_mb = $walMB; min_wal_mb = $minWalMB; wal_buf_kb = $walBufKB
        par = $par; gather = $gather; avw = $avw; iow = $iow; mwp = $mwp; conns = $conns; backends = $backends
        mwm_kb = $mwmKB; avwm_kb = $avwmKB; work_kb = $workKB; temp_kb = $tempKB; eic = $eic; rpc = $rpc; locks = $locks; over_kb = $overKB
    }
}
function TuneMBs([int64]$kb) { "$([int64]($kb / 1024))MB" }

# Every setting, from the plan. The reasons are tune-pg.sh's.
function TuneDeclared {
    $p = TunePlan
    $logs = (Join-Path $env:LAPLACE_WORK 'logs\postgres') -replace '\\', '/'
    # the libraries loaded at start: each declared one only when its DLL is in the server's library directory or one of
    # LAPLACE_PG_LIBDIRS, since a name the server cannot load stops it at its next start; a missing one is said
    $libdirs = @(Join-Path $env:LAPLACE_PG_DIR 'lib') + @($env:LAPLACE_PG_LIBDIRS -split ';' | Where-Object { $_ })
    $preload = @(($(if ($env:LAPLACE_PG_PRELOAD) { $env:LAPLACE_PG_PRELOAD } else { 'pg_stat_statements,auto_explain' }) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Where-Object {
        $name = $_; $found = $libdirs | Where-Object { Test-Path (Join-Path $_ "$name.dll") } | Select-Object -First 1
        if (-not $found) { Write-Warning "tune-pg: $name is declared for shared_preload_libraries but no $name.dll is in $($libdirs -join ';'): not loaded" }
        [bool]$found
    })
    $s = [ordered]@{
        wal_level                        = 'minimal'
        max_wal_senders                  = '0'
        shared_buffers                   = TuneMBs $p.shared_kb
        effective_cache_size             = TuneMBs $p.ecs_kb
        work_mem                         = TuneMBs $p.work_kb
        maintenance_work_mem             = TuneMBs $p.mwm_kb
        autovacuum_work_mem              = TuneMBs $p.avwm_kb
        temp_buffers                     = TuneMBs $p.temp_kb
        hash_mem_multiplier              = '1.0'
        huge_pages                       = 'off'
        io_method                        = 'worker'
        io_workers                       = "$($p.iow)"
        effective_io_concurrency         = "$($p.eic)"
        maintenance_io_concurrency       = "$($p.eic)"
        random_page_cost                 = $p.rpc
        default_toast_compression        = 'lz4'
        max_wal_size                     = "$($p.wal_mb)MB"
        max_slot_wal_keep_size           = "$($p.wal_mb)MB"
        min_wal_size                     = "$($p.min_wal_mb)MB"
        wal_buffers                      = TuneMBs $p.wal_buf_kb
        wal_compression                  = 'zstd'
        checkpoint_timeout               = '60min'
        checkpoint_completion_target     = '0.9'
        bgwriter_lru_maxpages            = '1000'
        max_worker_processes             = "$($p.mwp)"
        max_parallel_workers             = "$($p.par)"
        max_parallel_workers_per_gather  = "$($p.gather)"
        max_parallel_maintenance_workers = "$($p.gather)"
        jit                              = 'off'
        enable_parallel_append           = 'on'
        gin_pending_list_limit           = '32MB'
        autovacuum_max_workers           = "$($p.avw)"
        autovacuum_naptime               = '10s'
        autovacuum_vacuum_cost_delay     = '0'
        autovacuum_vacuum_cost_limit     = '2000'
        autovacuum_vacuum_scale_factor   = '0.05'
        autovacuum_analyze_scale_factor  = '0.02'
        autovacuum_vacuum_insert_scale_factor = '0.01'
        max_locks_per_transaction        = "$($p.locks)"
        shared_preload_libraries         = ($preload -join ',')
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
        port                             = $env:LAPLACE_PGPORT
        max_connections                  = "$($p.conns)"
        superuser_reserved_connections   = '3'
        max_prepared_transactions        = '32'
    }
    if ($TuneProfile -eq 'knowledge' -and $env:LAPLACE_PGTEMP) { $s['temp_tablespaces'] = 'pgtemp' }
    $s
}

function TuneShowPlan {
    $p = TunePlan
    "tune-pg: the facts of $env:COMPUTERNAME for the $TuneProfile profile"
    foreach ($k in $p.Keys) { if ($k -like 'fact.*') { '  {0,-24} {1}' -f $k.Substring(5), $p[$k] } }
    'tune-pg: the settings they give'
    $d = TuneDeclared; foreach ($k in $d.Keys) { '  {0,-40} {1}' -f $k, $d[$k] }
    if ($p.over_kb -gt 0) { Write-Warning "tune-pg: OVER-COMMITTED by $([int64]($p.over_kb / 1024)) MB: the connections declared, at PostgreSQL's floors, want more than the backends' quarter; fewer serving connections (LAPLACE_PG_SERVING) or more memory for the server (LAPLACE_PG_RESERVED)" }
}

# an ingest of the database laplace.env.ps1 names holds its lock open (no sharing) while it runs
function TuneIngesting {
    $db = if ($env:LAPLACE_CONNINFO -match 'dbname=(\S+)') { $Matches[1] } else { 'default' }
    $l = Join-Path $env:LAPLACE_LOCKS "ingest-$db.lock"
    if (-not (Test-Path $l)) { return $false }
    try { $fs = [IO.File]::Open($l, 'Open', 'ReadWrite', 'None'); $fs.Close(); $false } catch { $true }
}

# the server is tuned from the machine that runs it: a client would hand it its own memory and cores
function TuneLocalOrDie {
    $h = if ($TuneConn -match 'host=(\S+)') { $Matches[1] } else { '' }
    if ($h -in '', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME) { return }
    $mine = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
    if ($h -in $mine) { return }
    throw "tune-pg: $h is not this machine: a server is tuned on the host that runs it (its memory, its cores, its drives), not from a client"
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
    TuneLocalOrDie
    $want = TuneDeclared; $n = 0
    foreach ($r in TuneReport) {
        # already the declared value and already recorded, or a postmaster knob already in force: writing that again
        # can mark a restart for a value the server is already running
        if ($r.match -eq 't' -and ($r.source -eq 'configuration file' -or $r.context -eq 'postmaster')) { continue }
        $v = $want[$r.name]
        # a list setting is written element by element: one quoted text holding commas is one element, and the server
        # then looks for a library named "pg_stat_statements,auto_explain,..." and does not start
        $sql = if ($r.name -in 'shared_preload_libraries', 'temp_tablespaces') { "ALTER SYSTEM SET $($r.name) = " + (($v -split ',' | ForEach-Object { "'" + ($_.Trim() -replace "'", "''") + "'" }) -join ', ') }
               else { "ALTER SYSTEM SET $($r.name) = '$($v -replace "'", "''")'" }
        TunePsql $sql | Out-Null
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
    if ($Plan) { TuneShowPlan; exit 0 }
    if ($Check) { if (TuneCheck) { exit 0 } else { exit 1 } }
    TuneApply
    TuneRestart | Out-Null
    if (-not (TuneCheck)) { exit 1 }
}

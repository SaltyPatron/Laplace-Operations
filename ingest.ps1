#Requires -Version 7
<#
  Ingest into the database on Windows: the counterpart of ingest.sh. One command runs every source in the order
  recipes\order gives, or the sources named; the run is measured as it goes (the write-ahead log it wrote, the
  statements it ran), then the install is checked (laplace status) and measured (laplace bench). One ingest per
  database at a time: the lock.
    pwsh -File ingest.ps1                  every source, in order
    pwsh -File ingest.ps1 wiktionary       the sources named
  Reads laplace.env.ps1 and the deployed install (deploy.ps1 builds the program and the perf-caches). Not profiled:
  ingest.sh records with perf, which has no counterpart here; VTune is the operator's own choice.
#>
param([Parameter(ValueFromRemainingArguments)][string[]]$Sources = @())
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
$db = if ($env:LAPLACE_CONNINFO -match 'dbname=(\S+)') { $Matches[1] } else { 'default' }
$laplace = Join-Path $env:LAPLACE_BUILD 'Laplace-Engine\icx-release\laplace.exe'
if (-not (Test-Path $laplace)) { Write-Error "no laplace program at $laplace`: deploy.ps1 builds it"; exit 1 }
foreach ($f in @($env:LAPLACE_TIER0, $env:LAPLACE_HIGHWAY)) { if (-not (Test-Path $f) -or (Get-Item $f).Length -eq 0) { Write-Error "no perf-caches at $f`: deploy.ps1 generates them"; exit 1 } }

# the lock: one ingest of a database at a time (ingest.sh: flock)
New-Item -ItemType Directory -Force $env:LAPLACE_LOCKS | Out-Null
$lockPath = Join-Path $env:LAPLACE_LOCKS "ingest-$db.lock"
try { $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Write-Host "an ingest of $db is already running: this one leaves"; exit 3 }
$log = Join-Path $env:LAPLACE_WORK ("logs\ingest-runs\" + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Force $log | Out-Null

function Sql([string]$q) { & "$env:LAPLACE_PG_DIR\bin\psql.exe" -X $env:LAPLACE_CONNINFO -Atq -F "`t" -c $q }
function Step([string]$name, [scriptblock]$body) {
    ''; "=== $name   $((Get-Date).ToUniversalTime().ToString('HH:mm:ss'))"
    $out = Join-Path $log "$name.log"
    & $body 2>&1 | Where-Object { "$_" -notmatch '^OMP: ' } | Tee-Object -FilePath $out
    if ($LASTEXITCODE) { "=== $name did not finish; what it said is in $out"; exit 1 }
}
# The write-ahead log the ingest writes, read in 64 MB samples a minute as it runs (ingest.sh: wal_sampler), by relation
function WalRead([string]$from, [string]$to) {
    Sql @"
WITH b AS (SELECT relfilenode, reldatabase, resource_manager, count(*) AS n, count(*) FILTER (WHERE block_fpi_length > 0) AS fpi,
             coalesce(sum(block_fpi_length), 0) AS fb, coalesce(sum(block_data_length), 0) AS db
           FROM pg_get_wal_block_info('$from', '$to', false) GROUP BY 1, 2, 3)
SELECT now()::timestamp(0), coalesce(pg_partition_root(c.oid)::regclass::text, c.relname, 'relfilenode ' || b.relfilenode), b.resource_manager,
  sum(b.n), sum(b.fpi), sum(b.fb), sum(b.db)
FROM b LEFT JOIN pg_class c ON c.relfilenode = b.relfilenode AND b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
GROUP BY 2, 3
"@ 2>$null | Add-Content -Path (Join-Path $log 'wal.tsv')
}
function WalSummary {
    $tsv = Join-Path $log 'wal.tsv'; if (-not (Test-Path $tsv)) { '  no log was read'; return }
    $rows = Import-Csv -Path $tsv -Delimiter "`t" -Header at, relation, kind, n, fpi, fb, db
    $by = $rows | Group-Object relation, kind | ForEach-Object {
        [pscustomobject]@{ relation = $_.Group[0].relation; kind = $_.Group[0].kind; images = ($_.Group | Measure-Object n -Sum).Sum
                           imagesGB = ($_.Group | Measure-Object fb -Sum).Sum / 1GB; dataGB = ($_.Group | Measure-Object db -Sum).Sum / 1GB } }
    '  {0,-44} {1,-8} {2,12} {3,10} {4,10}' -f 'relation', 'kind', 'page images', 'images GB', 'data GB'
    $by | Sort-Object { $_.imagesGB + $_.dataGB } -Descending | Select-Object -First 30 | ForEach-Object { '  {0,-44} {1,-8} {2,12} {3,10:N2} {4,10:N2}' -f $_.relation, $_.kind, $_.images, $_.imagesGB, $_.dataGB }
    '  every relation, in the sample (64 MB a minute): {0} page images, {1:N2} GB of them; {2:N2} GB of data' -f ($rows | Measure-Object n -Sum).Sum, (($rows | Measure-Object fb -Sum).Sum / 1GB), (($rows | Measure-Object db -Sum).Sum / 1GB)
}
function StatementsSummary {
    Sql "SELECT calls, round(total_exec_time / 1000) AS s, round(mean_exec_time::numeric, 2) AS ms, rows, left(regexp_replace(query, '\s+', ' ', 'g'), 160)
         FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) ORDER BY total_exec_time DESC LIMIT 25" | Tee-Object -FilePath (Join-Path $log 'statements.txt')
}

Sql 'CREATE EXTENSION IF NOT EXISTS pg_walinspect' | Out-Null
$from = Sql 'SELECT pg_current_wal_lsn()'
if (-not (Sql 'SELECT pg_stat_statements_reset()')) { '  pg_stat_statements was not emptied: the statements report counts from before this run' }
$sampler = Start-ThreadJob -ArgumentList $from, $log, $env:LAPLACE_PG_DIR, $env:LAPLACE_CONNINFO -ScriptBlock {
    param($from, $log, $pg, $conninfo)
    function Sql([string]$q) { & "$pg\bin\psql.exe" -X $conninfo -Atq -F "`t" -c $q }
    while ($true) {
        Start-Sleep -Seconds 60
        $to = Sql 'SELECT pg_current_wal_lsn()'; if (-not $to) { continue }
        $upto = Sql "SELECT LEAST('$to'::pg_lsn, '$from'::pg_lsn + 67108864)"
        Set-Content -Path (Join-Path $log 'wal.from') -Value $to
        [pscustomobject]@{ from = $from; to = $upto } | ConvertTo-Json -Compress | Add-Content -Path (Join-Path $log 'wal.ranges')
        $from = $to
    }
}
Set-Content -Path (Join-Path $log 'wal.from') -Value $from
try {
    Step ingest { & $laplace ingest @Sources }                          # the sources named, or every source in order
} finally {
    Stop-Job $sampler -ErrorAction SilentlyContinue | Out-Null; Remove-Job $sampler -Force -ErrorAction SilentlyContinue
    # every sampled range, read now (reading inside the sampler would hold a query open past the ingest)
    if (Test-Path (Join-Path $log 'wal.ranges')) { Get-Content (Join-Path $log 'wal.ranges') | ForEach-Object { $r = $_ | ConvertFrom-Json; WalRead $r.from $r.to } }
    $last = Get-Content (Join-Path $log 'wal.from'); $end = Sql "SELECT LEAST(pg_current_wal_lsn(), '$last'::pg_lsn + 67108864)"; WalRead $last $end
    $lock.Dispose()
}
Step wal        { WalSummary }
Step statements { StatementsSummary }
Step status     { & $laplace status }
Step bench      { & $laplace bench }
''; "=== done   $((Get-Date).ToUniversalTime().ToString('HH:mm:ss'))   $log"

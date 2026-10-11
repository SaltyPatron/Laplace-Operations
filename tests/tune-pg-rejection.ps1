#Requires -Version 7
$ErrorActionPreference = 'Stop'
$env:LAPLACE_PGDATA = 'E:\fixture\pgdata'
$env:LAPLACE_PGWAL = 'D:\fixture\wal'
$env:LAPLACE_PG_DIR = 'C:\fixture\pgsql'
$env:LAPLACE_WORK = 'C:\fixture\work'
$env:LAPLACE_PGPORT = '5432'
$env:LAPLACE_CONNINFO = 'host=localhost dbname=postgres'
$env:TUNE_FACT_RAM_KB = '50037756'
$env:TUNE_FACT_THREADS = '32'
$env:TUNE_FACT_CORES = '24'
$env:TUNE_FACT_WAL_BYTES = '2000381014016'
$env:TUNE_FACT_WAL_SHARED = '1'
$env:TUNE_FACT_ROTATIONAL = '0'
$env:LAPLACE_PG_RESERVED = '34GB'
$env:LAPLACE_PG_BUFFERS_MAX = '1GB'
Remove-Item Env:LAPLACE_PG_SERVING, Env:LAPLACE_PG_PROFILE -ErrorAction SilentlyContinue
. "$PSScriptRoot\..\tune-pg.ps1"
$script:databaseTouched = $false
function TuneLocalOrDie { }
function TuneReport { $script:databaseTouched = $true }
function TunePsql { throw 'This fixture must never contact a database' }
$rejected = $false
try { TuneApply | Out-Null } catch {
    if ($_.Exception.Message -notmatch 'OVER-COMMITTED') { throw }
    $rejected = $true
}
if (-not $rejected -or $script:databaseTouched) {
    throw 'An overcommitted plan reached the database boundary instead of being refused'
}
# A fitting plan must still be admitted by the same guard; no actual DB is involved.
$env:TUNE_FACT_RAM_KB = '131799160'
$env:TUNE_FACT_THREADS = '12'
$env:TUNE_FACT_CORES = '6'
$env:LAPLACE_PG_RESERVED = '0'
Remove-Item Env:LAPLACE_PG_BUFFERS_MAX -ErrorAction SilentlyContinue
TuneValidatePlan
$env:LAPLACE_PG_WORK_NODES = '0'
$rejected = $false
try { TuneApply | Out-Null } catch {
    if ($_.Exception.Message -notmatch 'LAPLACE_PG_WORK_NODES') { throw }
    $rejected = $true
}
if (-not $rejected -or $script:databaseTouched) { throw 'An invalid operator population reached the database' }
$env:LAPLACE_PG_WORK_NODES = '4'
TuneValidatePlan
'PostgreSQL overcommit refusal before database access: passed'

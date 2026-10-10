#Requires -Version 7
$ErrorActionPreference = 'Stop'
$env:LAPLACE_PGDATA = 'E:\Data\Laplace\pgdata'
$env:LAPLACE_PGWAL = 'D:\Data\Laplace\pg_wal'
$env:LAPLACE_PGPORT = '5432'
$env:LAPLACE_PG_DIR = 'D:\test-pg'
$env:LAPLACE_CONNINFO = 'host=localhost dbname=postgres'
Remove-Item Env:TUNE_FACT_WAL_BYTES, Env:LAPLACE_PG_WAL_DEDICATED -ErrorAction SilentlyContinue
. "$PSScriptRoot\..\tune-pg.ps1"
# Only the OS capacity lookup is mocked; paths and dedication classification are real.
function Get-PSDrive { param($Name) [pscustomobject]@{ Used = 1GB; Free = 1999GB } }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$wal = TuneFactWal
Assert ($wal[0] -eq 2000GB -and $wal[1] -eq 1) 'Different drive must default to shared'
$env:LAPLACE_PG_WAL_DEDICATED = '1'
$wal = TuneFactWal
Assert ($wal[1] -eq 0) 'An explicitly dedicated separate drive must be recognized'
$env:LAPLACE_PGWAL = 'E:\Data\Laplace\pg_wal'
$rejected = $false
try { TuneFactWal | Out-Null } catch { $rejected = $true }
Assert $rejected 'PGDATA and dedicated WAL on the same drive must be rejected'
$env:LAPLACE_PG_WAL_DEDICATED = '0'
Assert ((TuneFactWal)[1] -eq 1) 'Same drive must be shared'
$env:LAPLACE_PG_WAL_DEDICATED = 'maybe'
$rejected = $false
try { TuneFactWal | Out-Null } catch { $rejected = $true }
Assert $rejected 'An invalid dedication declaration must fail'
'tune-pg Windows WAL classification: passed'

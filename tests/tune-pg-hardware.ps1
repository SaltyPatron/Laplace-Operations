#Requires -Version 7
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/../tune-pg.ps1"
Remove-Item Env:TUNE_FACT_RAM_KB, Env:TUNE_FACT_THREADS, Env:TUNE_FACT_CORES -ErrorAction SilentlyContinue
function Get-CimInstance { throw 'Hardware detection must not require CIM' }
$facts = TuneHardware
if ($facts.RamKB -le 0 -or $facts.Cores -lt 1 -or $facts.Threads -lt $facts.Cores) { throw 'Invalid measured hardware' }
if ((TuneFactRamKB) -ne $facts.RamKB -or (TuneFactCores) -ne $facts.Cores -or (TuneFactThreads) -ne $facts.Threads) { throw 'Inconsistent measured facts' }
$env:TUNE_FACT_RAM_KB = '131799160'
$env:TUNE_FACT_THREADS = '12'
$env:TUNE_FACT_CORES = '6'
if ((TuneFactRamKB) -ne 131799160 -or (TuneFactThreads) -ne 12 -or (TuneFactCores) -ne 6) { throw 'Explicit facts not honored' }
$env:TUNE_FACT_RAM_KB = '0'
$rejected = $false
try { TunePlan | Out-Null } catch { $rejected = $_.Exception.Message -like '*invalid hardware facts*' }
if (-not $rejected) { throw 'Zero-memory plan accepted' }
"Windows hardware: $($facts.RamKB) kB, $($facts.Cores) physical cores, $($facts.Threads) logical processors; override and rejection checks passed"

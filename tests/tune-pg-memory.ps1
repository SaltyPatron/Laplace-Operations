#Requires -Version 7
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/../tune-pg.ps1"
$bash = if (Test-Path 'C:/Program Files/Git/bin/bash.exe') { 'C:/Program Files/Git/bin/bash.exe' } else { (Get-Command bash -ErrorAction Stop).Source }
Remove-Item Env:LAPLACE_PG_ACTIVE_QUERIES, Env:LAPLACE_PG_SERVING, Env:LAPLACE_PG_WORK_NODES -ErrorAction SilentlyContinue

function Assert-Memory($p) {
    if ($p.backends -ne $p.active_queries + $p.par) { throw 'Parallel workers missing from executor budget' }
    if ($p.temp_total_kb -ne $p.conns * $p.temp_kb) { throw 'Connection temporary buffers missing' }
    $used = $p.backends * $p.work_nodes * $p.work_kb + $p.temp_total_kb + $p.mwm_kb + $p.avw * $p.avwm_kb
    if ($p.over_kb -ne [math]::Max($used - $p.private_kb, 0)) { throw 'Incorrect overcommit accounting' }
    if ($p.work_kb -lt 4096 -or $p.temp_kb -ne 8192) { throw 'Invalid memory floors' }
}
function Assert-Platforms($p) {
    $lines = & $bash -c '. "$1"; plan' memory-plan (($PSScriptRoot + '/../tune-pg.sh') -replace '\\', '/')
    if ($LASTEXITCODE) { throw 'Linux plan failed' }
    $linux = @{}
    foreach ($line in $lines) { $k, $v = $line -split '=', 2; $linux[$k] = $v }
    foreach ($k in $p.Keys) {
        if ([string]$p[$k] -cne [string]$linux[$k]) { throw "Platform mismatch: $k Windows=$($p[$k]) Linux=$($linux[$k])" }
    }
}

# Real machine facts, then the same explicit host matrix used by the Linux test.
$env:LAPLACE_PG_RESERVED = '0'
Remove-Item Env:TUNE_FACT_RAM_KB, Env:TUNE_FACT_THREADS, Env:TUNE_FACT_CORES -ErrorAction SilentlyContinue
$local = TunePlan
Assert-Memory $local
if ($local.active_queries -ne [math]::Min($local['fact.cores'], $local.conns - 3)) { throw 'Active population does not reflect physical cores' }
"Measured host: $($local['fact.memory_kb']) kB RAM, $($local['fact.cores']) cores, $($local.conns) slots, $($local.active_queries) active leaders, $($local.par) parallel workers, work_mem=$(TuneMBs $local.work_kb)"
$fixtures = @(
    @('substrate',131799160,12,6,68719476736,0,0,'0','0'),
    @('substrate',32862256,8,4,17179869184,0,0,'0','0'),
    @('app',4007004,2,1,53687091200,1,0,'0','0'),
    @('substrate',50037756,32,24,2147483648000,1,0,'34GB','1GB'),
    @('app',2048000,1,1,21474836480,1,1,'0','0'),
    @('substrate',50037756,32,24,2000381014016,1,0,'0','1GB'),
    @('substrate',17000003,7,3,21474836481,1,0,'0','0')
)
foreach ($f in $fixtures) {
    $script:TuneProfile = $env:LAPLACE_PG_PROFILE = $f[0]
    $env:TUNE_FACT_RAM_KB = [string]$f[1]; $env:TUNE_FACT_THREADS = [string]$f[2]; $env:TUNE_FACT_CORES = [string]$f[3]
    $env:TUNE_FACT_WAL_BYTES = [string]$f[4]; $env:TUNE_FACT_WAL_SHARED = [string]$f[5]; $env:TUNE_FACT_ROTATIONAL = [string]$f[6]
    $env:LAPLACE_PG_RESERVED = $f[7]; $env:LAPLACE_PG_BUFFERS_MAX = $f[8]
    $p = TunePlan; Assert-Memory $p; Assert-Platforms $p
}
$baseline = TunePlan
$env:LAPLACE_PG_ACTIVE_QUERIES = '1'
$single = TunePlan; Assert-Memory $single; Assert-Platforms $single
if ($single.conns -ne $baseline.conns -or $single.work_kb -le $baseline.work_kb) { throw 'Active population incorrectly changes connection capacity or fails to free executor memory' }
$env:LAPLACE_PG_SERVING = '100'
$idle = TunePlan; Assert-Memory $idle; Assert-Platforms $idle
if ($idle.active_queries -ne 1 -or $idle.backends -ne $single.backends -or $idle.temp_total_kb -le $single.temp_total_kb) { throw 'Idle slots incorrectly treated as active queries or lost their temp allowance' }
foreach ($invalid in @('0','-1','01','1.5','abc','1000000', [string]($idle.conns - 2))) {
    $env:LAPLACE_PG_ACTIVE_QUERIES = $invalid
    $rejected = $false
    try { TunePlan | Out-Null } catch { $rejected = $_.Exception.Message -like '*LAPLACE_PG_ACTIVE_QUERIES*' }
    if (-not $rejected) { throw "Invalid active population accepted: $invalid" }
    & $bash -c '. "$1"; plan' memory-plan (($PSScriptRoot + '/../tune-pg.sh') -replace '\\', '/') *> $null
    if ($LASTEXITCODE -eq 0) { throw "Linux accepted invalid active population: $invalid" }
}
$env:LAPLACE_PG_ACTIVE_QUERIES = '1'
$env:LAPLACE_PG_WORK_NODES = '4'
$four = TunePlan; Assert-Memory $four; Assert-Platforms $four
if ($four.work_kb -gt $idle.work_kb / 2) { throw 'Simultaneous work nodes omitted' }
'Executor memory accounting, workload validation and seven Windows/Linux host plans: passed'

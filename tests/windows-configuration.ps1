[CmdletBinding()]
param([string]$LaplaceRoot = $env:LAPLACE_ACCEPTANCE_SOURCE)
$ErrorActionPreference = 'Stop'
$ops = Split-Path $PSScriptRoot -Parent
if (-not $LaplaceRoot) { . "$ops/laplace.env.ps1"; $LaplaceRoot = [IO.Path]::Combine($env:LAPLACE_SRC, 'Laplace') }
$LaplaceRoot = (Resolve-Path -LiteralPath $LaplaceRoot).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('laplace-config-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch)
$keys = @('LAPLACE_SRC','LAPLACE_DATA','LAPLACE_DATA_ROOT','LAPLACE_DEPLOY','LAPLACE_WORK','LAPLACE_BUILD','LAPLACE_BUILD_ROOT','LAPLACE_EXTERNAL','LAPLACE_ENGINE_BUILD','LAPLACE_PGDATA','LAPLACE_PGWAL','LAPLACE_PGUSER','LAPLACE_PG_SERVICE_ACCOUNT','LAPLACE_CONFIG_SOURCE')
function Run([string]$exe, [string[]]$arguments, [hashtable]$extra = @{}) {
    $p = [Diagnostics.ProcessStartInfo]::new($exe)
    $p.UseShellExecute = $false; $p.RedirectStandardInput = $true; $p.RedirectStandardOutput = $true; $p.RedirectStandardError = $true
    foreach ($key in @($p.Environment.Keys)) { if ($key -match '^(LAPLACE_|PGPASSWORD$|INGEST$|REPOS$)') { [void]$p.Environment.Remove($key) } }
    $p.Environment['LAPLACE_MACHINE_ENV'] = Join-Path $scratch 'machine.env'
    $p.Environment['LAPLACE_ROOT'] = $LaplaceRoot
    foreach ($key in $extra.Keys) { $p.Environment[$key] = $extra[$key] }
    foreach ($arg in $arguments) { $p.ArgumentList.Add($arg) }
    $child = [Diagnostics.Process]::Start($p)
    $child.StandardInput.Close()
    $stdout = $child.StandardOutput.ReadToEndAsync(); $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(60000)) { $child.Kill($true); throw "$exe timed out" }
    if ($child.ExitCode -ne 0) { throw "$exe failed ($($child.ExitCode)): $($stderr.GetAwaiter().GetResult()) $($stdout.GetAwaiter().GetResult())" }
    $stdout.GetAwaiter().GetResult()
}
function PowershellValues([string]$script, [string]$tail = '', [hashtable]$extra = @{}) {
    $code = ". '$($script.Replace("'", "''"))'; $tail; Get-ChildItem Env:LAPLACE_* | ForEach-Object { [pscustomobject]@{ Name = `$_.Name; Value = `$_.Value } } | ConvertTo-Json -Compress"
    $rows = Run 'pwsh' @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) $extra | ConvertFrom-Json
    $result = @{}; foreach ($row in $rows) { $result[$row.Name] = $row.Value }; $result
}
try {
    @'
# Non-default roots, quoted paths and CMD metacharacters must remain data.
LAPLACE_SRC="Z:\sources & tests"
LAPLACE_DATA=Y:\corpora
LAPLACE_WORK=Y:\state\work
LAPLACE_DATA_ROOT=Y:\state
LAPLACE_BUILD=X:\build roots
LAPLACE_PGWAL=W:\wal
LAPLACE_ROLE=substrate_login
LAPLACE_PG_SERVICE_ACCOUNT=NT SERVICE\LaplacePostgres
'@ | Set-Content -LiteralPath (Join-Path $scratch 'machine.env')
    $batch = Join-Path $scratch 'read.cmd'
    @"
@echo off
call "$LaplaceRoot\scripts\win\env.cmd"
if errorlevel 1 exit /b 1
set LAPLACE
if defined PGPASSWORD exit /b 9
"@ | Set-Content -LiteralPath $batch
    foreach ($override in @(@{}, @{ LAPLACE_BUILD_ROOT = 'V:\override build'; LAPLACE_PGUSER = 'operator_login'; LAPLACE_DEPLOY = 'V:\installed deployment' })) {
        $ps = PowershellValues (Join-Path $ops 'laplace.env.ps1') '' $override
        $cmd = @{}
        foreach ($line in ((Run 'cmd.exe' @('/d','/c',$batch) $override) -split '\r?\n')) {
            if ($line -match '^(LAPLACE_[^=]+)=(.*)$') { $cmd[$Matches[1]] = $Matches[2] }
        }
        $monoPs = PowershellValues (Join-Path $LaplaceRoot 'scripts/win/laplace-paths.ps1') 'Import-LaplaceEnv' $override
        $python = Run 'py' @('-3',(Join-Path $LaplaceRoot 'scripts/machine-env.py'),'--paths','--format','json','--checkout',$LaplaceRoot) $override | ConvertFrom-Json
        $properties = (($keys + 'BaseOutputPath','LaplaceBuildWin') -join ',')
        $ms = (Run 'dotnet' @('msbuild', (Join-Path $LaplaceRoot 'app/Laplace.Core/Laplace.Core.csproj'), '-nologo', "-getProperty:$properties") $override | ConvertFrom-Json).Properties
        foreach ($key in $keys) {
            $expected = ([string]$ps[$key]).Replace('/', '\')
            foreach ($entry in @(@{name='CMD';value=$cmd[$key]}, @{name='Laplace PowerShell';value=$monoPs[$key]}, @{name='MSBuild';value=$ms.$key})) {
                if (([string]$entry.value).Replace('/', '\') -ne $expected) { throw "$key differs: Operations=$expected; $($entry.name)=$($entry.value)" }
            }
        }
        if ($ms.LaplaceBuildWin -ne $ps.LAPLACE_ENGINE_BUILD) { throw 'MSBuild native copy uses a different engine tree' }
        if (-not $ms.BaseOutputPath.StartsWith($ps.LAPLACE_BUILD_ROOT)) { throw 'Managed outputs escaped the configured build root' }
        $deployed=if($override.ContainsKey('LAPLACE_DEPLOY')){$override.LAPLACE_DEPLOY}else{'Y:\state\deploy'}
        foreach($values in $ps,$cmd,$monoPs){if($values.LAPLACE_DEPLOY -ne $deployed){throw 'Installed PostgreSQL overlay did not select persistent state consistently.'}}
        foreach($key in @('LAPLACE_BUILD_ROOT','LAPLACE_DATA_ROOT','LAPLACE_DEPLOY','LAPLACE_PGDATA','LAPLACE_PGWAL')){
            if($python.$key -ne $ps[$key]){throw "Python resolves a different $key`: $($python.$key); expected $($ps[$key])"}
        }
    }
    $canonical=@{LAPLACE_SRC=(Split-Path $LaplaceRoot -Parent)}
    $canonicalPs=PowershellValues (Join-Path $ops 'laplace.env.ps1') '' $canonical
    $canonicalPython=Run 'py' @('-3',(Join-Path $LaplaceRoot 'scripts/machine-env.py'),'--paths','--format','json','--checkout',$LaplaceRoot) $canonical | ConvertFrom-Json
    if($canonicalPython.LAPLACE_BUILD_ROOT -ne $canonicalPs.LAPLACE_BUILD_ROOT -or $canonicalPs.LAPLACE_BUILD_ROOT -ne [IO.Path]::Combine($canonicalPs.LAPLACE_BUILD,'Laplace')){throw 'The canonical checkout selected a duplicate Python build tree.'}
    foreach ($bad in @("LAPLACE_BUILD=one`nLAPLACE_BUILD=two", 'this is not a configuration assignment')) {
        Set-Content -LiteralPath (Join-Path $scratch 'machine.env') -Value $bad
        foreach ($entry in @(
            @{exe='pwsh'; argv=@('-NoProfile','-File',(Join-Path $ops 'laplace.env.ps1'))},
            @{exe='cmd.exe'; argv=@('/d','/c',$batch)},
            @{exe='dotnet'; argv=@('msbuild',(Join-Path $LaplaceRoot 'app/Laplace.Core/Laplace.Core.csproj'),'-nologo','-t:LaplaceValidateMachineConfiguration')}
        )) {
            $rejected = $false
            try { $null = Run $entry.exe $entry.argv } catch { $rejected = $true }
            if (-not $rejected) { throw "$($entry.exe) accepted invalid machine configuration: $bad" }
        }
    }
    'PASS: Operations PowerShell, Laplace PowerShell, CMD and bare MSBuild agree on alternate roots, identities, provenance and process overrides; no default password.'
    'PASS: duplicate keys and malformed declarations block PowerShell, CMD and MSBuild.'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup escaped temporary directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

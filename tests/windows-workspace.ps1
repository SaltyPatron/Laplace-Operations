#Requires -Version 7
[CmdletBinding()]
param([string]$LaplaceRoot = $env:LAPLACE_ACCEPTANCE_SOURCE)
$ErrorActionPreference = 'Stop'
if (-not $LaplaceRoot) { . "$PSScriptRoot/../laplace.env.ps1"; $LaplaceRoot = Join-Path $env:LAPLACE_SRC 'Laplace' }
$LaplaceRoot = (Resolve-Path -LiteralPath $LaplaceRoot).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('laplace-workspace-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch)
$worktrees = @()
function Run([string]$Program, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($key in 'LAPLACE_BUILD_ROOT','LAPLACE_ENGINE_BUILD','LAPLACE_ROOT','LAPLACE_ENV_LOADED','Platform') { [void]$info.Environment.Remove($key) }
    $info.Environment['LAPLACE_BUILD'] = Join-Path $scratch 'builds'
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($info)
    $out = $child.StandardOutput.ReadToEndAsync(); $err = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(120000)) { $child.Kill($true); throw "$Program timed out" }
    if ($child.ExitCode) { throw "$Program failed: $($out.GetAwaiter().GetResult()) $($err.GetAwaiter().GetResult())" }
    $out.GetAwaiter().GetResult()
}
try {
    $other = & git -C $LaplaceRoot rev-parse --verify 'HEAD^2' 2>$null
    if ($LASTEXITCODE) { $other = Run git @('-C',$LaplaceRoot,'rev-parse','HEAD~1') }
    $refs = @('HEAD', $other.Trim()); $built = @()
    foreach ($index in 0,1) {
        $path = Join-Path $scratch "source-$index"
        $null = Run git @('-C',$LaplaceRoot,'worktree','add','--detach',$path,$refs[$index])
        $worktrees += $path
        $project = Join-Path $path 'app/Laplace.Core/Laplace.Core.csproj'
        $null = Run dotnet @('build',$project,'-c','Release','--nologo','-v','quiet')
        $properties = (Run dotnet @('msbuild',$project,'-nologo','-p:Configuration=Release','-getProperty:LAPLACE_BUILD_ROOT,TargetPath') | ConvertFrom-Json).Properties
        if (-not $properties.LAPLACE_BUILD_ROOT.StartsWith((Join-Path $scratch 'builds'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Build output escaped the declared test root.' }
        $built += [ordered]@{source=$path; revision=(Run git @('-C',$path,'rev-parse','HEAD')).Trim(); build_root=$properties.LAPLACE_BUILD_ROOT; artifact=$properties.TargetPath; sha256=(Get-FileHash $properties.TargetPath).Hash}
    }
    if ($built[0].build_root -eq $built[1].build_root -or $built[0].revision -eq $built[1].revision) { throw 'Worktrees did not isolate distinct revisions.' }
    foreach ($leaf in 'installed','data') { [void](New-Item -ItemType Directory -Path (Join-Path $scratch $leaf)); Set-Content -LiteralPath (Join-Path $scratch "$leaf/keep") -Value 'preserve' }
    $null = Run dotnet @('clean',(Join-Path $worktrees[0] 'app/Laplace.Core/Laplace.Core.csproj'),'-c','Release','--nologo','-v','quiet')
    if ((Get-FileHash -LiteralPath $built[1].artifact).Hash -ne $built[1].sha256) { throw 'Cleaning one worktree changed the other artifact.' }
    foreach ($leaf in 'installed','data') { if ((Get-Content -LiteralPath (Join-Path $scratch "$leaf/keep") -Raw).Trim() -ne 'preserve') { throw 'Clean changed persistent/runtime data.' } }
    [ordered]@{verified=$true; builds=$built; clean_preserved_other_artifact=$true; clean_preserved_sentinels=$true} | ConvertTo-Json -Depth 5
} finally {
    $absolute = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup escaped the temporary workspace.' }
    foreach ($path in $worktrees) { $null = Run git @('-C',$LaplaceRoot,'worktree','remove',$path) }
    Remove-Item -LiteralPath $absolute -Recurse -Force
}

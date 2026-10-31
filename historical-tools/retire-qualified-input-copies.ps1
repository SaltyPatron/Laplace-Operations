#Requires -Version 7
$ErrorActionPreference='Stop'
$audit=[IO.Path]::GetFullPath($PSScriptRoot)
$expected='E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z'
if($audit -cne $expected){throw 'Unexpected audit directory.'}
$source=[IO.Path]::GetFullPath((Join-Path $audit 'qualified-native-inputs'))
$candidate=[IO.Path]::GetFullPath((Join-Path $audit 'native-candidate-tier0.bin'))
$prepared='E:\Data\Laplace\work\tier0'
if([IO.Path]::GetDirectoryName($source) -cne $audit -or [IO.Path]::GetDirectoryName($candidate) -cne $audit){throw 'Generated input cleanup escaped its reviewed root.'}
$items=@(Get-Item -LiteralPath $source)+@(Get-ChildItem -LiteralPath $source -Recurse -Force)+@(Get-Item -LiteralPath $candidate)
if(@($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Generated inputs contain a reparse point.'}
$manifest=Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
foreach($name in $manifest.Keys){
    if($name -notin @('tier0.bin','tier0.flags','tier0.flags.layout','tier0.highway')){throw 'Unexpected prepared input.'}
    foreach($file in (Join-Path $source $name),(Join-Path $prepared $name)){
        if((Get-Item -LiteralPath $file).Length -ne $manifest[$name].bytes -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest[$name].sha256){throw "Prepared input copy differs: $file"}
    }
}
if($manifest['tier0.bin'].bytes -ne 1114112*64 -or
   (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest['tier0.bin'].sha256){throw 'Candidate cache does not match the installed preparation store.'}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $audit 'qualified-native-inputs-manifest.json') -Encoding utf8
$bytes=(@($items | Where-Object {-not $_.PSIsContainer}) | Measure-Object Length -Sum).Sum
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($candidate,'OnlyErrorDialogs','SendToRecycleBin')
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($source,'OnlyErrorDialogs','SendToRecycleBin')
if((Test-Path -LiteralPath $source) -or (Test-Path -LiteralPath $candidate)){throw 'A duplicate generated input remains.'}
[ordered]@{status='passed';finished_utc=[DateTime]::UtcNow.ToString('o');mode='windows_recycle_bin';
    retired=@($candidate,$source);bytes=$bytes;preserved_prepared_store=$prepared;
    proof='Every generated input hash matched the canonical prepared store; no active CMake profile referenced the audit input paths.'} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $audit 'qualified-input-copy-retirement.json') -Encoding utf8
Write-Output 'Duplicate generated input copies recycled; canonical prepared inputs and their manifest retained.'

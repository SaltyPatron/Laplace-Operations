#Requires -Version 7
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($Source)
$destination = [IO.Path]::GetFullPath($Output)
if ($destination.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Grammar output must be outside the source directory.' }
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$parsers = @(Get-ChildItem -LiteralPath $sourceRoot -Filter parser.c -Recurse -File | Where-Object { $_.Directory.Name -eq 'src' -and $_.FullName -notmatch '\\node_modules\\' })
if (-not $parsers.Count) { throw "No grammar parsers found in $sourceRoot" }
$built = @()
foreach ($parser in $parsers) {
    $match = [regex]::Match([IO.File]::ReadAllText($parser.FullName), 'TSLanguage\s*\*\s*(tree_sitter_([A-Za-z0-9_]+))\s*\(void\)')
    if (-not $match.Success) { throw "No exported language function in $($parser.FullName)" }
    $name = $match.Groups[2].Value
    $binary = Join-Path $destination "libtree-sitter-$name.dll"
    if ($name -in $built) { throw "Multiple selected parsers export $name" }
    $sources = @($parser.FullName)
    foreach ($scanner in 'scanner.c','scanner.cc','scanner.cpp') {
        $file = Join-Path $parser.DirectoryName $scanner
        if (Test-Path -LiteralPath $file) { $sources += $file }
    }
    $log = Join-Path $destination "$name.build.log"
    $arguments = @('--driver-mode=gcc','-O2','-shared','-fms-runtime-lib=dll',"-Wl,/NODEFAULTLIB:libcmt,/EXPORT:$($match.Groups[1].Value)",
        ('-I' + $parser.DirectoryName), ('-I' + (Join-Path $parser.Directory.Parent.Parent.FullName 'common')), '-o', $binary) + $sources
    & icx.exe @arguments *> $log
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $binary)) { throw "Grammar $name failed; compiler output: $log" }
    $built += $name
    Write-Host "Built grammar $name"
}
[ordered]@{ source=$sourceRoot; output=$destination; grammars=$built } | ConvertTo-Json -Depth 3 |
    Set-Content -LiteralPath (Join-Path $destination 'grammars.json')

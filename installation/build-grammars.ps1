#Requires -Version 7
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Output,
      [string]$BuildDirectory)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($Source)
$destination = [IO.Path]::GetFullPath($Output)
if ($destination -eq $sourceRoot -or $destination.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Grammar output must be outside the source directory.' }
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $env:LAPLACE_BUILD 'deps/grammars' }
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
if ($BuildDirectory -eq $sourceRoot -or $BuildDirectory.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Generated grammar sources must be outside the source directory.'
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$parsers = @(Get-ChildItem -LiteralPath $sourceRoot -Filter parser.c -Recurse -File | Where-Object { $_.Directory.Name -eq 'src' -and $_.FullName -notmatch '\\node_modules\\' } | ForEach-Object {
    [pscustomobject]@{File=$_;ScannerRoot=$_.DirectoryName;CommonRoot=(Join-Path $_.Directory.Parent.Parent.FullName 'common')}
})
$definitions = @(Get-ChildItem -LiteralPath $sourceRoot -Filter grammar.js -Recurse -File | Where-Object { $_.FullName -notmatch '\\node_modules\\' })
$definitions += @(Get-ChildItem -LiteralPath $sourceRoot -Filter grammar.json -Recurse -File | Where-Object {
    $_.Directory.Name -eq 'src' -and $_.FullName -notmatch '\\node_modules\\' -and -not (Test-Path -LiteralPath (Join-Path $_.Directory.Parent.FullName 'grammar.js'))
})
foreach ($definition in $definitions) {
    $package = if ($definition.Name -eq 'grammar.json') { $definition.Directory.Parent } else { $definition.Directory }
    if (Test-Path -LiteralPath (Join-Path $package.FullName 'src/parser.c')) { continue }
    $exportReceipt = Join-Path $package.FullName '.laplace-source.json'
    if (Test-Path -LiteralPath $exportReceipt) {
        $receipt = Get-Content -LiteralPath $exportReceipt -Raw | ConvertFrom-Json
        $locked = @(Import-Csv -LiteralPath "$PSScriptRoot/../grammars.lock.tsv" -Delimiter "`t" | Where-Object name -eq $package.Name)
        if ($locked.Count -ne 1 -or $receipt.commit -ne $locked[0].commit -or $receipt.origin -ne $locked[0].origin) { throw "Grammar export does not match the lock: $exportReceipt" }
        foreach ($file in $receipt.files) {
            $path = [IO.Path]::GetFullPath((Join-Path $package.FullName $file.path))
            if (-not $path.StartsWith($package.FullName + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Grammar export escaped its root.' }
            $bytes = [IO.File]::ReadAllBytes($path)
            $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
            $sha = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))).ToLowerInvariant()
            if ($sha -ne $file.sha) { throw "Grammar source blob differs from its pin: $path" }
        }
    }
    $generator = (Get-Command tree-sitter.exe -ErrorAction Stop).Source
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($definition.FullName))).Substring(0,12).ToLowerInvariant()
    $generated = Join-Path $BuildDirectory ($package.Name + '-' + $key)
    New-Item -ItemType Directory -Path $generated -Force | Out-Null
    $log = Join-Path $generated 'generate.log'
    $previousLibdir = $env:TREE_SITTER_LIBDIR
    try {
        $env:TREE_SITTER_LIBDIR = Join-Path $BuildDirectory 'cache'
        & $generator generate $definition.FullName --output (Join-Path $generated 'src') --abi 15 --js-runtime native *> $log
    } finally { $env:TREE_SITTER_LIBDIR = $previousLibdir }
    if ($LASTEXITCODE) { throw "Grammar generation failed: $log" }
    $parser = Get-Item -LiteralPath (Join-Path $generated 'src/parser.c')
    $parsers += [pscustomobject]@{File=$parser;ScannerRoot=(Join-Path $package.FullName 'src');CommonRoot=(Join-Path $package.Parent.FullName 'common')}
}
if (-not $parsers.Count) { throw "No grammar parsers found in $sourceRoot" }
$built = @()
foreach ($entry in $parsers) {
    $parser = $entry.File
    $match = [regex]::Match([IO.File]::ReadAllText($parser.FullName), 'TSLanguage\s*\*\s*(tree_sitter_([A-Za-z0-9_]+))\s*\(void\)')
    if (-not $match.Success) { throw "No exported language function in $($parser.FullName)" }
    $name = $match.Groups[2].Value
    $binary = Join-Path $destination "libtree-sitter-$name.dll"
    if ($name -in $built) { throw "Multiple selected parsers export $name" }
    $sources = @($parser.FullName)
    foreach ($scanner in 'scanner.c','scanner.cc','scanner.cpp') {
        $file = Join-Path $entry.ScannerRoot $scanner
        if (Test-Path -LiteralPath $file) { $sources += $file }
    }
    $log = Join-Path $destination "$name.build.log"
    $arguments = @('--driver-mode=gcc','-O2','-shared','-fms-runtime-lib=dll',"-Wl,/NODEFAULTLIB:libcmt,/EXPORT:$($match.Groups[1].Value)",
        ('-I' + $parser.DirectoryName), ('-I' + $entry.ScannerRoot), ('-I' + $entry.CommonRoot), '-o', $binary) + $sources
    & icx.exe @arguments *> $log
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $binary)) { throw "Grammar $name failed; compiler output: $log" }
    $built += $name
    Write-Host "Built grammar $name"
}
[ordered]@{ source=$sourceRoot; output=$destination; grammars=$built } | ConvertTo-Json -Depth 3 |
    Set-Content -LiteralPath (Join-Path $destination 'grammars.json')

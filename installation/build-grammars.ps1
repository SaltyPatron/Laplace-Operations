#Requires -Version 7
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Output,
      [string]$BuildDirectory, [string]$ExternalSource)
$ErrorActionPreference = 'Stop'
# Receipts bind source contents, toolchain/options and output contents. File
# timestamps alone cannot establish that a generated parser or DLL is current.
function Grammar-Files([string[]]$Roots, [string[]]$Extensions) {
    @($Roots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Recurse -File -Force | Where-Object {
            $_.FullName -notmatch '[\\/](?:node_modules|\.git)[\\/]' -and $_.Extension -in $Extensions
        }
    } | Sort-Object FullName -Unique)
}
function Grammar-Key([object[]]$Files, [string[]]$Options) {
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($value in $Options) {
            $bytes=[Text.Encoding]::UTF8.GetBytes([string]$value)
            $hash.AppendData([BitConverter]::GetBytes([long]$bytes.Length)); $hash.AppendData($bytes)
        }
        foreach ($file in $Files | Sort-Object FullName -Unique) {
            foreach ($bytes in @([Text.Encoding]::UTF8.GetBytes($file.FullName),[IO.File]::ReadAllBytes($file.FullName))) {
                $hash.AppendData([BitConverter]::GetBytes([long]$bytes.Length)); $hash.AppendData($bytes)
            }
        }
        [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $hash.Dispose() }
}
function Grammar-Current([string]$Receipt, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Receipt)) { return $false }
    try {
        $record=Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json
        if ($record.schema -ne 'laplace.grammar-build/v1' -or $record.inputs -ne $Key -or -not $record.outputs.Count) { return $false }
        foreach ($file in $record.outputs) {
            if (-not (Test-Path -LiteralPath $file.path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ine $file.sha256) { return $false }
        }
        return $true
    } catch { return $false }
}
function Grammar-Receipt([string]$Path, [string]$Key, [object[]]$Files) {
    $outputs=@($Files | ForEach-Object { @{path=$_.FullName;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,(@{schema='laplace.grammar-build/v1';inputs=$Key;outputs=$outputs} | ConvertTo-Json -Depth 4))
        [IO.File]::Move($temporary,$Path,$true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
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
$generator=(Get-Command tree-sitter.exe -ErrorAction Stop).Source
$compiler=(Get-Command icx.exe -ErrorAction Stop).Source
$builderHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$toolchain=@($builderHash,$generator,(Get-FileHash -LiteralPath $generator).Hash,$compiler,(Get-FileHash -LiteralPath $compiler).Hash,
    $env:INCLUDE,$env:LIB,$env:LIBPATH,$env:VCToolsVersion,$env:WindowsSDKVersion)
$generatedCount=0; $compiledCount=0; $reusedCount=0
$parsers = @(Get-ChildItem -LiteralPath $sourceRoot -Filter parser.c -Recurse -File | Where-Object { $_.Directory.Name -eq 'src' -and $_.FullName -notmatch '\\node_modules\\' } | ForEach-Object {
    [pscustomobject]@{File=$_;ScannerRoot=$_.DirectoryName;CommonRoot=(Join-Path $_.Directory.Parent.Parent.FullName 'common')}
})
$definitions = @(Get-ChildItem -LiteralPath $sourceRoot -Filter grammar.js -Recurse -File | Where-Object { $_.FullName -notmatch '\\node_modules\\' })
$definitions += @(Get-ChildItem -LiteralPath $sourceRoot -Filter grammar.json -Recurse -File | Where-Object {
    $_.Directory.Name -eq 'src' -and $_.FullName -notmatch '\\node_modules\\' -and -not (Test-Path -LiteralPath (Join-Path $_.Directory.Parent.FullName 'grammar.js'))
})
foreach ($derivation in Get-ChildItem -LiteralPath $sourceRoot -Filter derivation.json -Recurse -File) {
    $owner = [IO.DirectoryInfo]::new($derivation.DirectoryName)
    while ($owner -and -not (Test-Path -LiteralPath (Join-Path $owner.FullName 'tools/prepare_grammar.py'))) { $owner = $owner.Parent }
    if (-not $ExternalSource -and $env:LAPLACE_GRAMMAR_SRC) { $ExternalSource = $env:LAPLACE_GRAMMAR_SRC }
    if (-not $ExternalSource -and $env:LAPLACE_EXTERNAL) { $ExternalSource = Join-Path $env:LAPLACE_EXTERNAL 'tree-sitter-grammars' }
    if (-not $owner -or -not $ExternalSource) { throw 'Grammar derivations require the Engine preparer and declared external sources.' }
    $preparer = Join-Path $owner.FullName 'tools/prepare_grammar.py'
    $prepared = & python $preparer $derivation.FullName $ExternalSource (Join-Path $BuildDirectory 'derived')
    if ($LASTEXITCODE) { throw "Grammar derivation failed: $($derivation.FullName)" }
    $specification = Get-Content -LiteralPath $derivation.FullName -Raw | ConvertFrom-Json
    $definition = if ('grammar' -in $specification.PSObject.Properties.Name) { $specification.grammar } else { 'grammar.js' }
    $definitions += Get-Item -LiteralPath (Join-Path $prepared $definition)
}
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
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($definition.FullName))).Substring(0,12).ToLowerInvariant()
    $generated = Join-Path $BuildDirectory ($package.Name + '-' + $key)
    New-Item -ItemType Directory -Path $generated -Force | Out-Null
    $log = Join-Path $generated 'generate.log'
    $relative = [IO.Path]::GetRelativePath($package.FullName, $definition.FullName).Replace('\','/')
    $generationReceipt=Join-Path $generated 'generate.receipt.json'
    $generationInputs=Grammar-Files @($package.FullName,(Join-Path $package.Parent.FullName 'common')) @('.js','.mjs','.cjs','.json')
    $generationKey=Grammar-Key $generationInputs ($toolchain+@('generate','--abi=15','--js-runtime=native',$relative))
    if (-not (Grammar-Current $generationReceipt $generationKey)) {
        $previousLibdir = $env:TREE_SITTER_LIBDIR
        try {
            $env:TREE_SITTER_LIBDIR = Join-Path $BuildDirectory 'cache'
            # QuickJS treats a Windows absolute path as a module specifier, not a file.
            # Resolve imports from the package and pass a relative grammar path.
            Push-Location $package.FullName
            try { & $generator generate $relative --output (Join-Path $generated 'src') --abi 15 --js-runtime native *> $log }
            finally { Pop-Location }
        } finally { $env:TREE_SITTER_LIBDIR = $previousLibdir }
        if ($LASTEXITCODE) { throw "Grammar generation failed: $log" }
        Grammar-Receipt $generationReceipt $generationKey (Grammar-Files @((Join-Path $generated 'src')) @('.c','.h','.json'))
        $generatedCount++
    }
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
    $compilationInputs=Grammar-Files @($parser.DirectoryName,$entry.ScannerRoot,$entry.CommonRoot) @('.c','.cc','.cpp','.h','.hpp','.inc','.inl')
    $compilationKey=Grammar-Key $compilationInputs ($toolchain+$arguments)
    $compilationReceipt=$binary+'.receipt.json'
    if (-not (Grammar-Current $compilationReceipt $compilationKey)) {
        & $compiler @arguments *> $log
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $binary)) { throw "Grammar $name failed; compiler output: $log" }
        Grammar-Receipt $compilationReceipt $compilationKey @(Get-Item -LiteralPath $binary)
        $compiledCount++
        Write-Host "Built grammar $name"
    } else { $reusedCount++ }
    $built += $name
}
$inventory=Join-Path $destination 'grammars.json'
$json=[ordered]@{ source=$sourceRoot; output=$destination; grammars=$built } | ConvertTo-Json -Depth 3
if (-not (Test-Path -LiteralPath $inventory) -or [IO.File]::ReadAllText($inventory).Trim() -ne $json.Trim()) {
    [IO.File]::WriteAllText($inventory,$json+"`n")
}
Write-Host "Grammar build: $generatedCount generated, $compiledCount compiled, $reusedCount reused."

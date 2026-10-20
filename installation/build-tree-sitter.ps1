#Requires -Version 7
<#
  Build the grammar generator from the same source pin as the Engine's runtime.
  Called by setup.ps1 deps, or independently by setup.ps1 tree-sitter. No host
  installation, user-profile toolchain, corpus acquisition, or database changes.
  Rust's three checksum-pinned components install into one isolated SDK prefix;
  Cargo's registry and target directory stay under the dependency build root.
#>
[CmdletBinding()]
param([switch]$Check, [switch]$Offline,
      [string]$BuildRoot, [string]$DependencyRoot, [string]$SourceRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This dependency build targets Windows x64, as declared in dependencies.tsv.'
}
if (-not $BuildRoot) { $BuildRoot = $env:LAPLACE_BUILD }
if (-not $DependencyRoot) { $DependencyRoot = $env:LAPLACE_DEPS }
if (-not $SourceRoot) { $SourceRoot = $env:LAPLACE_DEPSRC }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$DependencyRoot = [IO.Path]::GetFullPath($DependencyRoot)
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$operations = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$rows = @(Get-Content -LiteralPath "$operations/dependencies.tsv" | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ConvertFrom-Csv -Delimiter "`t")
function Row([string]$Name) {
    $selected = @($rows | Where-Object name -eq $Name)
    if ($selected.Count -ne 1) { throw "Expected one dependencies.tsv row for $Name." }
    $selected[0]
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function LockHash([string]$Path) {
    # A Git checkout may translate line endings; the manifest pins UTF-8/LF.
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n", "`n"))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Invoke-Tool([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE) { throw "$Program exited $LASTEXITCODE." }
}
function Git([string[]]$Arguments) {
    $result = & git.exe -c "safe.directory=$($source.Replace('\','/'))" -c core.excludesFile= -C $source @Arguments
    if ($LASTEXITCODE) { throw "Tree-sitter Git operation failed: $($Arguments -join ' ')." }
    $result
}
function Remove-OwnedDirectory([string]$Path, [string]$Owner) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($Owner).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup escaped $Owner : $absolute" }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}
function Fetch-Archive($Component, [string]$Directory) {
    $file = Join-Path $Directory $Component.archive
    if (Test-Path -LiteralPath $file) {
        if ((Hash $file) -ne $Component.sha256) { throw "Cached archive checksum differs: $file" }
        return $file
    }
    if ($Offline) { throw "Offline dependency archive is absent: $file" }
    $temporary = "$file.download-$([guid]::NewGuid().ToString('N'))"
    try {
        Write-Host "Fetching compiler component $($Component.archive)"
        Invoke-WebRequest -Uri "$($rustLock.origin)/$($Component.archive)" -OutFile $temporary -TimeoutSec 60
        if ((Hash $temporary) -ne $Component.sha256) { throw "Downloaded archive checksum differs: $($Component.archive)" }
        Move-Item -LiteralPath $temporary -Destination $file
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    $file
}
$runtime = Row 'tree-sitter'
$cli = Row 'tree-sitter-cli'
$rust = Row 'rust'
if ($cli.pin -ne $runtime.pin -or $cli.origin -ne $runtime.origin) { throw 'CLI and runtime must name the identical Tree-sitter source pin.' }
if ($cli.build -ne 'cargo' -or $rust.build -ne 'rust-components') { throw 'Unexpected dependency build declarations.' }
$lockPath = Join-Path $operations 'toolchain/rust.lock.json'
if ((LockHash $lockPath) -ne $rust.pin) { throw 'Rust component lock differs from dependencies.tsv.' }
$rustLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
if ($rustLock.version -ne $rust.version -or $rustLock.origin -ne $rust.origin) { throw 'Rust component lock and dependency row disagree.' }
$source = Join-Path $SourceRoot $runtime.name
$build = Join-Path $BuildRoot 'deps/tree-sitter-cli'
$sdk = Join-Path $DependencyRoot "rust/$($rust.version)"
$prefix = Join-Path $DependencyRoot "tree-sitter-cli/$($cli.version)"
$program = Join-Path $prefix $cli.proof
$receiptPath = Join-Path $prefix 'build-receipt.json'
$cargo = Join-Path $sdk 'bin/cargo.exe'
$rustc = Join-Path $sdk 'bin/rustc.exe'
if (-not (Test-Path -LiteralPath "$source/.git")) {
    if ($Check -or $Offline) { throw "Pinned Tree-sitter source is absent: $source" }
    [void](New-Item -ItemType Directory -Force -Path $SourceRoot)
    Invoke-Tool git.exe @('clone', '--filter=blob:none', '--no-checkout', $runtime.origin, $source)
    Git @('-c','advice.detachedHead=false','checkout','--detach',$runtime.pin) | Out-Host
}
$origin = [string](Git @('remote','get-url','origin'))
if ($origin.TrimEnd('/') -replace '\.git$' -ne ($runtime.origin.TrimEnd('/') -replace '\.git$')) { throw "Unexpected source origin: $origin" }
$revision = [string](Git @('rev-parse','HEAD'))
if ($revision -ne $runtime.pin) { throw "Tree-sitter source is $revision, expected $($runtime.pin); existing checkout preserved." }
if (Git @('status','--porcelain','--untracked-files=normal')) { throw 'Tree-sitter source has local changes; existing checkout preserved.' }
$sourceLock = Join-Path $source 'Cargo.lock'
$lockHash = Hash $sourceLock
$sdkLockHash = LockHash $lockPath
if ((Test-Path -LiteralPath $program) -and (Test-Path -LiteralPath $receiptPath)) {
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.source_commit -eq $revision -and $receipt.cargo_lock_sha256 -eq $lockHash -and
        $receipt.rust_lock_sha256 -eq $sdkLockHash -and $receipt.binary_sha256 -eq (Hash $program)) {
        Invoke-Tool $program @('--version')
        Write-Host "Verified Tree-sitter CLI: $program"
        return
    }
}
if ($Check) { throw "No verified Tree-sitter CLI at $prefix" }
[void](New-Item -ItemType Directory -Force -Path $build)
$buildLock = [IO.File]::Open((Join-Path $build '.build.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$oldEnvironment = @{}
foreach ($name in 'PATH','CARGO_HOME','CARGO_TARGET_DIR','RUSTC','RUSTDOC','CC','CXX','TREE_SITTER_LIBDIR') { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $sdkReceipt = Join-Path $sdk 'component-receipt.json'
    $sdkValid = (Test-Path -LiteralPath $rustc) -and (Test-Path -LiteralPath $cargo) -and (Test-Path -LiteralPath $sdkReceipt)
    if ($sdkValid) {
        $record = Get-Content -LiteralPath $sdkReceipt -Raw | ConvertFrom-Json
        $sdkValid = $record.lock_sha256 -eq $sdkLockHash
        foreach ($file in $record.files) {
            $path = Join-Path $sdk $file.path
            if (-not (Test-Path -LiteralPath $path) -or (Hash $path) -ne $file.sha256) { $sdkValid = $false; break }
        }
    }
    if (-not $sdkValid) {
        if (Test-Path -LiteralPath $sdk) { throw "Existing SDK failed verification at $sdk; preserved for inspection." }
        $cache = Join-Path $BuildRoot "deps/rust/$($rust.version)/downloads"
        [void](New-Item -ItemType Directory -Force -Path $cache)
        $parent = Split-Path $sdk
        [void](New-Item -ItemType Directory -Force -Path $parent)
        $stage = Join-Path $parent (".$($rust.version).install-" + [guid]::NewGuid().ToString('N'))
        $extract = Join-Path $BuildRoot ('deps/rust/extract-' + [guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Force -Path $stage, $extract)
            foreach ($component in $rustLock.components) {
                $archive = Fetch-Archive $component $cache
                Invoke-Tool tar.exe @('-xf', $archive, '-C', $extract)
                $package = Join-Path $extract ($component.archive -replace '\.tar\.xz$','')
                foreach ($part in Get-Content -LiteralPath (Join-Path $package 'components')) {
                    if ($part -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid Rust component path.' }
                    $directory = Join-Path $package $part
                    # Official rust-installer payload: install files only; no installer,
                    # uninstall script, PATH registration, docs, or user-profile writes.
                    foreach ($line in Get-Content -LiteralPath (Join-Path $directory 'manifest.in')) {
                        if ($line -notmatch '^(file|dir):(.+)$') { throw "Unknown Rust manifest entry: $line" }
                        $kind = $Matches[1]; $relative = $Matches[2]
                        $target = [IO.Path]::GetFullPath((Join-Path $stage $relative))
                        if (-not $target.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Rust payload escaped its prefix.' }
                        [void](New-Item -ItemType Directory -Force -Path (Split-Path $target))
                        if ($kind -eq 'dir') {
                            [void](New-Item -ItemType Directory -Force -Path $target)
                            Get-ChildItem -LiteralPath (Join-Path $directory $relative) -Force | ForEach-Object {
                                Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
                            }
                        }
                        else { Copy-Item -LiteralPath (Join-Path $directory $relative) -Destination $target -Force }
                    }
                }
            }
            $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
                @{path=[IO.Path]::GetRelativePath($stage,$_.FullName);sha256=Hash $_.FullName}
            })
            @{lock_sha256=$sdkLockHash;files=$files} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$stage/component-receipt.json"
            [IO.Directory]::Move($stage, $sdk)
        } finally {
            Remove-OwnedDirectory $stage $parent
            Remove-OwnedDirectory $extract (Join-Path $BuildRoot 'deps/rust')
        }
    }
    # Native crates (Tree-sitter and QuickJS) use the existing ICX/VS environment.
    . $env:LAPLACE_DEVSHELL
    [void](Get-Command icx.exe -ErrorAction Stop)
    $env:PATH = "$(Join-Path $sdk 'bin');$env:PATH"
    $env:CARGO_HOME = Join-Path $BuildRoot 'deps/cargo-home'
    $env:CARGO_TARGET_DIR = Join-Path $build 'target'
    $env:TREE_SITTER_LIBDIR = Join-Path $build 'grammar-cache'
    $env:RUSTC = $rustc
    $env:RUSTDOC = Join-Path $sdk 'bin/rustdoc.exe'
    $env:CC = 'icx'; $env:CXX = 'icx'
    $compilerVersion = [string](& $rustc --version)
    if ($LASTEXITCODE -or $compilerVersion -notmatch ('^rustc ' + [regex]::Escape($rust.version) + ' ')) { throw "Unexpected Rust compiler: $compilerVersion" }
    $arguments = @('build','--locked','--release','--target',$rustLock.target,'--manifest-path',(Join-Path $source 'Cargo.toml'),'--package','tree-sitter-cli','--bin','tree-sitter')
    if ($Offline) { $arguments += '--offline' }
    Invoke-Tool $cargo $arguments
    $built = Join-Path $env:CARGO_TARGET_DIR "$($rustLock.target)/release/tree-sitter.exe"
    Invoke-Tool $built @('--version')
    # Acceptance uses the actual generator and an actual DLL build, outside the
    # upstream checkout. The included QuickJS runtime needs no Node installation.
    $probe = Join-Path $build 'verify'
    [void](New-Item -ItemType Directory -Force -Path $probe)
    [IO.File]::WriteAllText((Join-Path $probe 'grammar.js'), "module.exports = grammar({name:'laplace_dependency_probe',rules:{source_file:`$ => repeat1(/[a-z]+/)}});`n")
    Push-Location $probe
    try { Invoke-Tool $built @('generate','--abi','15','--js-runtime','native') } finally { Pop-Location }
    $binary = Join-Path $probe 'probe.dll'
    Invoke-Tool icx.exe @('--driver-mode=gcc','-O2','-shared','-fms-runtime-lib=dll','-Wl,/NODEFAULTLIB:libcmt,/EXPORT:tree_sitter_laplace_dependency_probe',('-I'+(Join-Path $probe 'src')),'-o',$binary,(Join-Path $probe 'src/parser.c'))
    if (-not (Test-Path -LiteralPath $binary)) { throw 'Generated grammar failed to compile.' }
    $inputFile = Join-Path $probe 'input.txt'
    [IO.File]::WriteAllText($inputFile, 'laplace')
    $config = Join-Path $probe 'config.json'
    [IO.File]::WriteAllText($config, '{}')
    $parsed = & $built parse --config-path $config --lib-path $binary --lang-name laplace_dependency_probe $inputFile
    if ($LASTEXITCODE -or ($parsed -join "`n") -notmatch 'source_file' -or ($parsed -join "`n") -match 'ERROR|MISSING') {
        throw "Generated grammar failed to parse its input: $($parsed -join ' ')"
    }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $program))
    Copy-Item -LiteralPath $built -Destination $program -Force
    [ordered]@{source_commit=$revision;cargo_lock_sha256=$lockHash;rust_lock_sha256=$sdkLockHash;
        rustc=$compilerVersion;binary_sha256=Hash $program;generator='QuickJS';grammar_abi=15;
        generated_parser_sha256=Hash (Join-Path $probe 'src/parser.c');grammar_dll_sha256=Hash $binary;
        parsed_input='laplace';parse_output=$parsed} |
        ConvertTo-Json | Set-Content -LiteralPath $receiptPath
    Write-Host "Built and verified Tree-sitter CLI: $program"
} finally {
    foreach ($name in $oldEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name]) }
    $buildLock.Dispose()
}

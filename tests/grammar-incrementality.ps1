# Real Tree-sitter + ICX acceptance. Uses the declared local toolchain; no mocks,
# corpus downloads, database writes or application publication.
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
$root=Join-Path $env:LAPLACE_BUILD ('acceptance/grammar-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source'; $dlls=Join-Path $root 'dlls'; $build=Join-Path $root 'build'
$results=@()
try {
    foreach ($name in @('a','b')) {
        $package=Join-Path $source $name
        $null=New-Item -ItemType Directory -Path (Join-Path $package 'src') -Force
        [IO.File]::WriteAllText((Join-Path $package 'grammar.js'),("const word=require('./rules.js'); module.exports=grammar({name:'laplace_cache_NAME',rules:{source_file:`$=>repeat1(word(`$))}});".Replace('NAME',$name)))
        [IO.File]::WriteAllText((Join-Path $package 'rules.js'),'module.exports = $ => /[a-z]+/;')
        [IO.File]::WriteAllText((Join-Path $package 'src/scanner.h'),'#define CACHE_VALUE 1')
        [IO.File]::WriteAllText((Join-Path $package 'src/scanner.c'),"#include `"scanner.h`"`nint cache_value(void){return CACHE_VALUE;}`n")
    }
    function Run([string]$Name,[int]$Generated,[int]$Compiled,[int]$Reused) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $lines=@(& pwsh -NoProfile -File "$PSScriptRoot/../installation/build-grammars.ps1" -Source $source -Output $dlls -BuildDirectory $build 2>&1)
        if ($LASTEXITCODE) { throw ($lines -join "`n") }
        $expected="Grammar build: $Generated generated, $Compiled compiled, $Reused reused."
        if ($lines -notcontains $expected) { throw "$Name expected $expected; got $($lines -join '`n')" }
        $script:results += @{case=$Name;generated=$Generated;compiled=$Compiled;reused=$Reused;seconds=$watch.Elapsed.TotalSeconds}
        Write-Host "$Name : $expected"
    }
    Run initial 2 2 0
    $a=Join-Path $dlls 'libtree-sitter-laplace_cache_a.dll'
    $b=Join-Path $dlls 'libtree-sitter-laplace_cache_b.dll'
    $times=@((Get-Item -LiteralPath $a).LastWriteTimeUtc.Ticks,(Get-Item -LiteralPath $b).LastWriteTimeUtc.Ticks)
    Run unchanged 0 0 2
    if ((Get-Item -LiteralPath $a).LastWriteTimeUtc.Ticks -ne $times[0] -or (Get-Item -LiteralPath $b).LastWriteTimeUtc.Ticks -ne $times[1]) { throw 'Unchanged DLLs were rewritten.' }
    [IO.File]::SetLastWriteTimeUtc((Join-Path $source 'a/rules.js'),[DateTime]::UtcNow)
    Run timestamp_only 0 0 2
    [IO.File]::WriteAllText((Join-Path $source 'a/rules.js'),'module.exports = $ => /[a-z0-9]+/;')
    Run changed_import 1 1 1
    [IO.File]::WriteAllText((Join-Path $source 'a/src/scanner.h'),'#define CACHE_VALUE 2')
    Run changed_scanner_header 0 1 1
    [IO.File]::AppendAllText($a,'corrupted')
    Run corrupted_dll 0 1 1
    $parser=Get-ChildItem -LiteralPath $build -Filter parser.c -Recurse | Where-Object { $_.FullName -match '[\\/]b-' } | Select-Object -First 1
    Remove-Item -LiteralPath $parser.FullName
    Run missing_generated_parser 1 0 2
    Run final_unchanged 0 0 2
    [ordered]@{passed=$true;checked_utc=[DateTime]::UtcNow.ToString('o');toolchain='declared Tree-sitter and ICX';cases=$results} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Output
} finally {
    $parent=[IO.Path]::GetFullPath((Join-Path $env:LAPLACE_BUILD 'acceptance')).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -ne $parent) { throw 'Test cleanup escaped its declared scratch root.' }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

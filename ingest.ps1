#Requires -Version 7
<# Compatibility entry point for the installed modular client's ingestion.
   Client selection owns the executable, database, recipes and perf-caches.
   Native ingestion owns its progress, source logs and database lifecycle.
   Use laplace bench separately when an operator requests a benchmark. #>
param([Parameter(ValueFromRemainingArguments)][string[]]$Sources = @())
$ErrorActionPreference = 'Stop'
$laplace=Join-Path $env:LOCALAPPDATA 'Laplace/bin/laplace.cmd'
if(-not(Test-Path -LiteralPath $laplace -PathType Leaf)){
    throw 'The modular client is not installed. Run setup.ps1 client for this host before ingestion.'
}
& $laplace ingest @Sources
exit $LASTEXITCODE

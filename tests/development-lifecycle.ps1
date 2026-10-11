#Requires -Version 7
# Runs the actual installed desktop build on a free loopback port.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../secrets/process.ps1"
$entry=(Resolve-Path "$PSScriptRoot/../laplace.ps1").Path
$savedPort=$env:LAPLACE_API_PORT
$savedToken=$env:BAO_TOKEN
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=$listener.LocalEndpoint.Port
$listener.Stop()
$env:LAPLACE_API_PORT=[string]$port
$env:BAO_TOKEN='invalid-operator-token-for-workload-identity-test'
$receiptPath=$null
$originalReceipt=$null
function Operation([string]$Name) { Invoke-Program pwsh @('-NoProfile','-File',$entry,$Name,'-Target','desktop') -TimeoutSeconds 210 }
function Result([string]$Text) { $Text.Substring($Text.IndexOf('{')) | ConvertFrom-Json }
try {
    if ((Result (Operation status)).status -ne 'stopped') { throw 'Test port is already owned by a managed desktop instance.' }
    $first=Result (Operation start)
    $receiptPath=Join-Path $first.logs 'receipt.json'
    $originalReceipt=Get-Content -LiteralPath $receiptPath -Raw
    $second=Result (Operation start)
    if ($first.pid -ne $second.pid) { throw 'Repeated start created another process.' }
    if ((Invoke-WebRequest $first.url -TimeoutSec 10).StatusCode -ne 200) { throw 'Started application did not serve its UI.' }
    foreach ($failure in 'process-start','application-path') {
        $tampered=$originalReceipt | ConvertFrom-Json
        if ($failure -eq 'process-start') { $tampered.process_started_utc=([DateTimeOffset]$tampered.process_started_utc).AddSeconds(1).ToString('o') }
        else { $tampered.api_path=Join-Path (Split-Path $tampered.api_path) 'another-application.dll' }
        $tampered | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath
        $null=Operation stop
        if (-not (Get-Process -Id $first.pid -ErrorAction SilentlyContinue)) { throw "Stop accepted a mismatched $failure." }
        [IO.File]::WriteAllText($receiptPath,$originalReceipt)
    }
    $null=Operation stop
    if ((Result (Operation status)).status -ne 'stopped' -or (Get-Process -Id $first.pid -ErrorAction SilentlyContinue)) { throw 'Stop left the application running.' }
    $originalReceipt=$null
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
    $listener.Start()
    try {
        $refused=$false
        try { $null=Operation start } catch { $refused=$true }
        if (-not $refused) { throw 'Start accepted a port belonging to another process.' }
        if (-not $listener.Server.IsBound) { throw 'Refusing start disturbed the existing listener.' }
    } finally { $listener.Stop() }
    @{passed=$true;port=$port;revision=$first.revision;run_directory=$first.logs;
      checks=@('workload-authenticated-start','ui-200','idempotent-start','process-start-mismatch-refused',
               'application-path-mismatch-refused','stop','occupied-port-refused')} | ConvertTo-Json -Depth 4
} finally {
    if ($originalReceipt -and $receiptPath) {
        [IO.File]::WriteAllText($receiptPath,$originalReceipt)
        $null=Operation stop
    }
    $env:LAPLACE_API_PORT=$savedPort
    $env:BAO_TOKEN=$savedToken
}

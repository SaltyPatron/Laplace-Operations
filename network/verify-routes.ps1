#Requires -Version 7
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
$receipt=Join-Path $env:LAPLACE_WORK ('operations/browser-routes-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
& py -3 "$PSScriptRoot/service-paths.py" --output $receipt
exit $LASTEXITCODE

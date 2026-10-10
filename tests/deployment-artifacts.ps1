$ErrorActionPreference='Stop'
$source=Get-Content (Join-Path $PSScriptRoot ../deploy.ps1) -Raw
$begin=$source.IndexOf('# Refuse missing artifacts')
$end=$source.IndexOf('# deploy.ps1 drop:', $begin)
if ($begin -lt 0 -or $end -le $begin) { throw 'preflight boundary missing' }
$preflight=[scriptblock]::Create($source.Substring($begin,$end-$begin))
if (-not $env:TMPDIR) { throw "set TMPDIR to build scratch storage" }
$root=Join-Path $env:TMPDIR ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $root | Out-Null
try {
    $env:LAPLACE_TIER0=Join-Path $root tier0.bin
    $env:LAPLACE_HIGHWAY=Join-Path $root tier0.highway
    $env:LAPLACE_FLAGS=''
    $files=@($env:LAPLACE_TIER0,(Join-Path $root tier0.flags),$env:LAPLACE_HIGHWAY,"$env:LAPLACE_HIGHWAY.layout","$env:LAPLACE_HIGHWAY.keys")
    foreach ($f in $files) { Set-Content -LiteralPath $f -Value prepared }
    & $preflight
    foreach ($f in $files) {
        Remove-Item -LiteralPath $f
        $refused=$false
        try { & $preflight } catch { if ($_.Exception.Message -notlike 'missing deployment artifact:*') { throw }; $refused=$true }
        if (-not $refused) { throw "accepted missing artifact $f" }
        Set-Content -LiteralPath $f -Value prepared
    }
    Write-Output 'PASS actual PowerShell preflight accepts prepared artifacts and rejects each missing file'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }

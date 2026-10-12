#Requires -Version 7
param([Parameter(Mandatory)][string]$Installation)
$ErrorActionPreference = 'Stop'
$declaration = [IO.Path]::GetFullPath($Installation)
$config = [IO.File]::ReadAllText($declaration) | ConvertFrom-Json
if ($config.host -ne $env:COMPUTERNAME) { throw 'The modular client declaration belongs to another host.' }
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
$python = & python -c 'import sys; print(sys.executable)'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python)) { throw 'The configured toolchain must provide an installed Python interpreter.' }
& $python "$PSScriptRoot/package-windows-client.py" --installation $declaration
if ($LASTEXITCODE -ne 0) { throw 'Modular client packaging failed; command selection was not changed.' }
$client = $config.operator_client
New-Item -ItemType Directory -Path $client.work -Force | Out-Null
$connection = Join-Path $client.work ('.connection-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $client.connection | ConvertTo-Json | Set-Content -LiteralPath $connection
    $command = Join-Path $env:LOCALAPPDATA 'Laplace/bin/laplace.cmd'
    & $python "$PSScriptRoot/install-client.py" --installation $config.installed_config --role $client.role `
        --work $client.work --data $client.data --configuration $client.configuration --command $command --connection $connection
    if ($LASTEXITCODE -ne 0) { throw 'Installed modular command verification failed.' }
    $bin = Split-Path $command
    $userPath = [string][Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($bin -notin @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('PATH', (($userPath.TrimEnd(';') + ';' + $bin).TrimStart(';')), 'User')
    }
    Write-Host "Installed laplace. Run laplace --where and laplace status from any directory."
} finally {
    Remove-Item -LiteralPath $connection -ErrorAction SilentlyContinue
}

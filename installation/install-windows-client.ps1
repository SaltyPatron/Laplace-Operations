#Requires -Version 7
param([Parameter(Mandatory)][string]$Installation, [switch]$SkipPackage)
$ErrorActionPreference = 'Stop'
$declaration = [IO.Path]::GetFullPath($Installation)
$config = [IO.File]::ReadAllText($declaration) | ConvertFrom-Json
if ($config.host -ne $env:COMPUTERNAME) { throw 'The modular client declaration belongs to another host.' }
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
$python = & python -c 'import sys; print(sys.executable)'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python)) { throw 'The configured toolchain must provide an installed Python interpreter.' }
if (-not $SkipPackage) {
    & $python "$PSScriptRoot/package-windows-client.py" --installation $declaration
    if ($LASTEXITCODE -ne 0) { throw 'Modular client packaging failed; command selection was not changed.' }
}
$client = $config.operator_client
New-Item -ItemType Directory -Path $client.work -Force | Out-Null
$connection = Join-Path $client.work ('.connection-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $client.connection | ConvertTo-Json | Set-Content -LiteralPath $connection
    $command = Join-Path $env:LOCALAPPDATA 'Laplace/bin/laplace.cmd'
    # Capture input locations at installation. The normal launcher must not
    # depend on a developer shell or inherit another client's LAPLACE_* values.
    $inputArgs = @()
    foreach ($root in @(@{Key='source'; Variable='LAPLACE_SRC'}, @{Key='models'; Variable='LAPLACE_MODELS'})) {
        $value = if ($client.($root.Key)) { $client.($root.Key) } else { [Environment]::GetEnvironmentVariable($root.Variable) }
        if ($value) {
            $inputArgs += ('--' + $root.Key)
            $inputArgs += [string]$value
        }
    }
    & $python "$PSScriptRoot/install-client.py" --installation $config.installed_config --role $client.role `
        --work $client.work --data $client.data --configuration $client.configuration --command $command --connection $connection @inputArgs
    if ($LASTEXITCODE -ne 0) { throw 'Installed modular command verification failed.' }
    $bin = Split-Path $command
    $opsCmd = Join-Path $bin 'laplace-ops.cmd'
    $opsPs1 = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../laplace.ps1'))
    $pwshExe = (Get-Command pwsh).Source
    Set-Content -LiteralPath $opsCmd -Value "@echo off`r`nsetlocal DisableDelayedExpansion`r`n`"$pwshExe`" -NoLogo -NoProfile -File `"$opsPs1`" %*`r`nexit /b %errorlevel%`r`n" -NoNewline
    $userPath = [string][Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($bin -notin @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('PATH', (($userPath.TrimEnd(';') + ';' + $bin).TrimStart(';')), 'User')
    }
    Write-Host "Installed laplace and laplace-ops. Run laplace --where, laplace status, or laplace-ops runs from any directory."
} finally {
    Remove-Item -LiteralPath $connection -ErrorAction SilentlyContinue
}
. "$PSScriptRoot/desktop-clients.ps1"
Write-DesktopClientState (Get-DesktopClientState -Declaration $config)

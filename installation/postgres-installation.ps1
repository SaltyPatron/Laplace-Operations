#Requires -Version 7
param([switch]$Check)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"

$prefix = [IO.Path]::GetFullPath($env:LAPLACE_PG_DIR).TrimEnd('\')
$pgbin = Join-Path $prefix 'bin'
$postgres = Join-Path $pgbin 'postgres.exe'
$version = & $postgres --version
if ($LASTEXITCODE -ne 0) { throw 'The selected PostgreSQL executable cannot run with its installed dependencies.' }
$pin = (Import-Csv -LiteralPath "$PSScriptRoot/../dependencies.tsv" -Delimiter "`t" | Where-Object name -EQ 'postgresql').version
if ($version -ne "postgres (PostgreSQL) $pin") { throw "The selected PostgreSQL differs from the dependency manifest: $pin" }
$reported = & (Join-Path $pgbin 'pg_config.exe') --bindir
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($reported) -ne $pgbin) { throw 'pg_config does not belong to the selected installation.' }
$registrations = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^PostgreSQL \d+\s*$' -and $_.InstallLocation })
$duplicates = @($registrations | Where-Object { [IO.Path]::GetFullPath($_.InstallLocation).TrimEnd('\') -ne $prefix })
$processes = @(Get-CimInstance Win32_Process -Filter "name='postgres.exe'")
foreach ($process in $processes) {
    if (-not $process.ExecutablePath -or [IO.Path]::GetFullPath($process.ExecutablePath) -ne $postgres) {
        throw "PostgreSQL process $($process.ProcessId) is not verified as the selected installation; adopt its data before uninstalling."
    }
}
$services = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match '(?i)\b(?:postgres|pg_ctl)\.exe\b' })
foreach ($service in $services) {
    if ($service.PathName -notlike "*$pgbin*" -and $service.State -ne 'Stopped') {
        throw "PostgreSQL service $($service.Name) still runs another installation."
    }
}
$removal = @()
foreach ($item in $duplicates) {
    $directory = [IO.Path]::GetFullPath($item.InstallLocation).TrimEnd('\')
    $uninstaller = Join-Path $directory 'uninstall-postgresql.exe'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf) -or (Get-Item -LiteralPath $uninstaller).Length -eq 0) {
        throw "The registered PostgreSQL uninstaller is missing or empty: $uninstaller"
    }
    $removal += [ordered]@{ name=$item.DisplayName.Trim(); prefix=$directory; uninstaller=$uninstaller }
}
$result = [ordered]@{ host=$env:COMPUTERNAME; prefix=$prefix; version=$version; running_processes=@($processes | ForEach-Object ProcessId); remove_installations=$removal }
if ($Check) { $result | ConvertTo-Json -Depth 5; return }
$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run setup.ps1 postgres in an administrator PowerShell; setup.ps1 postgres -Check makes no changes.'
}
$receipts = Join-Path $env:LAPLACE_WORK 'logs/postgres-installation'
New-Item -ItemType Directory -Path $receipts -Force | Out-Null
$receipt = Join-Path $receipts ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffffffZ') + '.json')
$result.status = 'started'
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receipt
try {
    foreach ($item in $removal) {
        $process = Start-Process -FilePath $item.uninstaller -ArgumentList @('--mode','unattended') -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -notin 0,3010) { throw "PostgreSQL uninstaller failed: $($item.name), exit $($process.ExitCode)" }
        if (Test-Path -LiteralPath (Join-Path $item.prefix 'bin/postgres.exe')) { throw "Duplicate executable remains after uninstall: $($item.prefix)" }
    }
    $oldBins = @($removal | ForEach-Object { Join-Path $_.prefix 'bin' })
    $path = @([Environment]::GetEnvironmentVariable('PATH','Machine').Split(';') | Where-Object {
        $_ -and $_.TrimEnd('\') -notin $oldBins -and $_.TrimEnd('\') -ne $pgbin
    })
    [Environment]::SetEnvironmentVariable('PATH', (($path + $pgbin) -join ';'), 'Machine')
    $env:PATH = "$pgbin;" + (@($env:PATH.Split(';') | Where-Object { $_.TrimEnd('\') -notin $oldBins -and $_.TrimEnd('\') -ne $pgbin }) -join ';')
    if ((Get-Command postgres.exe).Source -ne $postgres) { throw 'The current shell does not resolve the selected PostgreSQL.' }
    $after = & $postgres --version
    if ($LASTEXITCODE -ne 0 -or $after -ne $version) { throw 'Selected PostgreSQL failed after consolidation.' }
    $result.status = 'passed'
} catch { $result.status = 'failed'; $result.error = $_.Exception.Message; throw }
finally { $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receipt; Write-Host "PostgreSQL consolidation receipt: $receipt" }

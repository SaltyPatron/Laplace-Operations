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
$uninstallRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
function Registrations {
    @(Get-ItemProperty ($uninstallRoots | ForEach-Object { "$_\*" }) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^PostgreSQL \d+\s*$' -and $_.InstallLocation })
}
$registrations = @(Registrations)
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
    if ($directory -eq [IO.Path]::GetPathRoot($directory).TrimEnd('\') -or
        $prefix.StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $directory.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Registered installation overlaps the selected installation: $directory"
    }
    $uninstaller = Join-Path $directory 'uninstall-postgresql.exe'
    $action = 'uninstall'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf) -or (Get-Item -LiteralPath $uninstaller).Length -eq 0) {
        # EDB can remove its own executable before a service-removal error interrupts it.
        # Recover only an orphan registration, never delete an installation tree or data.
        $executables = @(Get-ChildItem -LiteralPath (Join-Path $directory 'bin') -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        if ($executables.Count -or @($services | Where-Object { $_.PathName -like "*$directory\*" }).Count) {
            throw "The registered PostgreSQL uninstaller is missing, but binaries or services remain: $directory"
        }
        $action = 'remove_orphan_registration'
    }
    $removal += [ordered]@{ name=$item.DisplayName.Trim(); prefix=$directory; uninstaller=$uninstaller; registration=$item.PSPath; action=$action }
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
        if ($item.action -eq 'uninstall') {
            $process = Start-Process -FilePath $item.uninstaller -ArgumentList @('--mode','unattended','--unattendedmodeui','none') -WindowStyle Hidden -Wait -PassThru
            $item.exit_code = $process.ExitCode
            if ($process.ExitCode -notin 0,3010) { throw "PostgreSQL uninstaller failed: $($item.name), exit $($process.ExitCode)" }
        }
        if (Test-Path -LiteralPath (Join-Path $item.prefix 'bin/postgres.exe')) { throw "Duplicate executable remains after uninstall: $($item.prefix)" }
        if (Test-Path -LiteralPath $item.registration) {
            $remaining = @(Get-ChildItem -LiteralPath (Join-Path $item.prefix 'bin') -Filter '*.exe' -File -ErrorAction SilentlyContinue)
            $registeredServices = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*$($item.prefix)\*" })
            if ($remaining.Count -or $registeredServices.Count) { throw "PostgreSQL components remain at $($item.prefix); registration preserved." }
            $key = Get-Item -LiteralPath $item.registration
            $allowedParents = @($uninstallRoots | ForEach-Object { (Get-Item -LiteralPath $_).Name })
            $keyParent = $key.Name.Substring(0, $key.Name.LastIndexOf('\'))
            if ($keyParent -notin $allowedParents) { throw 'Registration is outside the Windows uninstall registry.' }
            $backup = Join-Path $receipts ((Split-Path $receipt -LeafBase) + '-' + $key.PSChildName + '.reg')
            & reg.exe export $key.Name $backup /y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not preserve orphan PostgreSQL registration before removing it.' }
            Remove-Item -LiteralPath $item.registration -Recurse -Force
            $item.registration_backup = $backup
        }
    }
    $oldBins = @($removal | ForEach-Object { Join-Path $_.prefix 'bin' })
    # An interrupted vendor uninstaller may finish after this script has exited,
    # taking its registration with it. Resume PATH cleanup from the recorded plan.
    foreach ($previous in Get-ChildItem -LiteralPath $receipts -Filter '*.json' -File) {
        $history = [IO.File]::ReadAllText($previous.FullName) | ConvertFrom-Json
        if ($history.host -ne $env:COMPUTERNAME -or $history.prefix -ne $prefix) { continue }
        foreach ($retired in $history.remove_installations) {
            if ($retired.name -notmatch '^PostgreSQL \d+$' -or -not [IO.Path]::IsPathFullyQualified($retired.prefix)) { continue }
            $retiredBin = Join-Path $retired.prefix 'bin'
            if ($retiredBin -ne $pgbin -and -not (Test-Path -LiteralPath (Join-Path $retiredBin 'postgres.exe'))) {
                $oldBins += $retiredBin
            }
        }
    }
    $path = @([Environment]::GetEnvironmentVariable('PATH','Machine').Split(';') | Where-Object {
        $_ -and $_.TrimEnd('\') -notin $oldBins -and $_.TrimEnd('\') -ne $pgbin
    })
    [Environment]::SetEnvironmentVariable('PATH', (($path + $pgbin) -join ';'), 'Machine')
    $env:PATH = "$pgbin;" + (@($env:PATH.Split(';') | Where-Object { $_.TrimEnd('\') -notin $oldBins -and $_.TrimEnd('\') -ne $pgbin }) -join ';')
    if ((Get-Command postgres.exe).Source -ne $postgres) { throw 'The current shell does not resolve the selected PostgreSQL.' }
    $after = & $postgres --version
    if ($LASTEXITCODE -ne 0 -or $after -ne $version) { throw 'Selected PostgreSQL failed after consolidation.' }
    $remaining = @(Registrations | Where-Object { [IO.Path]::GetFullPath($_.InstallLocation).TrimEnd('\') -ne $prefix })
    if ($remaining.Count) { throw 'Another PostgreSQL installation remains registered.' }
    $result.status = 'passed'
} catch { $result.status = 'failed'; $result.error = $_.Exception.Message; throw }
finally {
    if ($result.status -eq 'started') { $result.status = 'interrupted'; $result.error = 'Setup ended before installed-state verification.' }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receipt
    Write-Host "PostgreSQL consolidation $($result.status); receipt: $receipt"
}

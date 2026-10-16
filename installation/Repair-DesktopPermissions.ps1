#Requires -Version 7
<#
.SYNOPSIS
    Repairs all Windows ACLs across HART-DESKTOP's Laplace directories and cleans up stale agent worktree/temp sprawl.
.DESCRIPTION
    Run once in an Administrator PowerShell prompt:
        pwsh -File E:\Repositories\Laplace\Laplace-Operations\installation\Repair-DesktopPermissions.ps1

    Why this exists:
    Windows UAC strips BUILTIN\Administrators (S-1-5-32-544) from your normal non-elevated shell token.
    Previously, elevated setup scripts used `Protect-IisDirectory` / `icacls /inheritance:r` and granted access only to
    SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544), omitting your actual user SID (HART-DESKTOP\ahart).
    That locked your normal non-elevated user shell out of directories on your own machine.

    What this script does:
    1. Grants your Windows user SID (HART-DESKTOP\ahart, S-1-5-21-1955383224-1799969050-1119319971-1001) explicit
       inheritable FullControl across all Laplace trees on E:, D:, and C: while keeping service accounts intact
       (NetworkService S-1-5-20 for PostgreSQL, IIS APPPOOL\laplace-mono for IIS).
    2. Removes the locked duplicate modular release directory so `install-windows-client.ps1` works cleanly without elevation.
    3. Cleans up stale agent worktree build directories (`D:\Libraries\build\Laplace\worktrees\*`) and one-off agent
       scratch files/tarballs/bundles in `E:\Data\Laplace\work`.
#>
[CmdletBinding()]
param(
    [string]$Configuration = "$PSScriptRoot/hart-desktop-operator.json",
    [switch]$SkipScratchCleanup
)
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script once from an elevated (Administrator) PowerShell prompt:`n  pwsh -File `"$PSCommandPath`""
}

$config = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json
$operatorSid = if ($config.windows_sid) { $config.windows_sid } else { $identity.User.Value }
$operatorName = if ($config.windows_identity) { $config.windows_identity } else { $identity.Name }

Write-Host "=== 1. Granting $operatorName ($operatorSid) FullControl across Laplace directories ===" -ForegroundColor Cyan

$roots = @(
    'E:\Data\Laplace',
    'E:\Data\Ingest',
    'E:\Repositories\Laplace',
    'D:\Libraries\build\Laplace',
    'D:\Data\Laplace',
    'C:\ProgramData\Laplace',
    'C:\Users\ahart\AppData\Local\Laplace'
)

foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Write-Host "   Taking ownership & granting FullControl on $root ..."
    & takeown.exe /F $root /R /D Y *> $null
    & icacls.exe $root /grant "*${operatorSid}:(OI)(CI)F" /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' /T /C /Q | Out-Null
}

# Ensure PostgreSQL service account (NT AUTHORITY\NetworkService = S-1-5-20) retains required access
foreach ($pgDir in @('E:\Data\Laplace\pgdata', 'D:\Data\Laplace\pg_wal', 'E:\Data\Laplace\work\logs\postgres')) {
    if (Test-Path -LiteralPath $pgDir) {
        & icacls.exe $pgDir /grant '*S-1-5-20:(OI)(CI)M' /T /C /Q | Out-Null
    }
}
if (Test-Path -LiteralPath 'D:\Libraries\postgresql\18.6') {
    & icacls.exe 'D:\Libraries\postgresql\18.6' /grant '*S-1-5-20:(OI)(CI)RX' /grant "*${operatorSid}:(OI)(CI)F" /T /C /Q | Out-Null
}

# Ensure IIS Application Pool retains required access to the IIS service directories
$iisRoot = 'E:\Data\Laplace\services\laplace-mono-api'
if (Test-Path -LiteralPath $iisRoot) {
    & icacls.exe $iisRoot /grant 'IIS APPPOOL\laplace-mono:(OI)(CI)RX' /C /Q | Out-Null
    foreach ($sub in @('state\keys', 'state\logs', 'state\output', 'receipts')) {
        $subPath = Join-Path $iisRoot $sub
        if (Test-Path -LiteralPath $subPath) {
            & icacls.exe $subPath /grant 'IIS APPPOOL\laplace-mono:(OI)(CI)M' /T /C /Q | Out-Null
        }
    }
}

Write-Host "=== 2. Cleaning up duplicate modular release folders ===" -ForegroundColor Cyan
$releasesDir = 'E:\Data\Laplace\services\laplace\releases'
if (Test-Path -LiteralPath $releasesDir) {
    Get-ChildItem -LiteralPath $releasesDir -Directory | Where-Object { $_.Name -match '-\d+$' -or $_.Name -like '.package-*' -or $_.Name -like '.stale-*' } | ForEach-Object {
        Write-Host "  Removing temporary/duplicate release folder: $($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}

if (-not $SkipScratchCleanup) {
    Write-Host "=== 3. Cleaning up stale agent worktree builds & scratch sprawl ===" -ForegroundColor Cyan
    $staleBuildPaths = @(
        'D:\Libraries\build\Laplace\worktrees',
        'D:\Libraries\build\Laplace\ingestion-maintenance-probe',
        'D:\Libraries\build\Laplace\ingestion-package-20261012',
        'D:\Libraries\build\Laplace\ingestion-repair-20261012',
        'D:\Libraries\build\Laplace\mono-uci-desktop',
        'D:\Libraries\build\Laplace\product-quality'
    )
    foreach ($p in $staleBuildPaths) {
        if (Test-Path -LiteralPath $p) {
            Write-Host "  Removing stale build directory: $p"
            Remove-Item -LiteralPath $p -Recurse -Force
        }
    }

    $workDir = 'E:\Data\Laplace\work'
    if (Test-Path -LiteralPath $workDir) {
        # Remove loose agent scratch files (.txt, .bundle, .tar, .patch, .log, .json, .py) at the root of E:\Data\Laplace\work
        Get-ChildItem -LiteralPath $workDir -File -Force | ForEach-Object {
            Write-Host "  Removing loose scratch file: $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Force
        }
        # Remove dated one-off agent directories in E:\Data\Laplace\work
        $keepWorkDirs = @('acceptance', 'audit', 'build', 'chess', 'clients', 'development', 'iis-packages', 'laplace-mono', 'locks', 'logs', 'modular-client', 'operations', 'verification')
        Get-ChildItem -LiteralPath $workDir -Directory -Force | Where-Object { $_.Name -notin $keepWorkDirs } | ForEach-Object {
            Write-Host "  Removing one-off agent work folder: $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
    }

    $staleBackupEnv = 'C:\ProgramData\Laplace\machine.env.before-config-contract-20261010'
    if (Test-Path -LiteralPath $staleBackupEnv) {
        Remove-Item -LiteralPath $staleBackupEnv -Force
    }
}

Write-Host "=== 4. Re-packaging and verifying non-elevated modular CLI ===" -ForegroundColor Cyan
$canonicalRelease = Get-ChildItem -LiteralPath $releasesDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if ($canonicalRelease -and (Test-Path -LiteralPath "$($canonicalRelease.FullName)\bin\laplace.exe")) {
    $rel = $canonicalRelease.FullName
    $env:PGSSLMODE = 'verify-full'
    $env:PGSSLROOTCERT = 'E:/Data/Laplace/clients/laplace/postgresql-desktop-ca.pem'
    $env:PGREQUIREAUTH = 'sspi'
    $env:LAPLACE_CONNINFO = 'host=HART-DESKTOP hostaddr=127.0.0.1 port=5432 user=ahart dbname=laplace sslmode=verify-full sslrootcert=E:/Data/Laplace/clients/laplace/postgresql-desktop-ca.pem require_auth=sspi connect_timeout=10'
    $env:LAPLACE_TIER0 = "$rel\share\prepared\tier0.bin"
    $env:LAPLACE_FLAGS = "$rel\share\prepared\tier0.flags"
    $env:LAPLACE_HIGHWAY = "$rel\share\prepared\tier0.highway"
    $env:LAPLACE_GRAMMARS = "$rel\share\grammars"
    $env:LAPLACE_UCD = 'D:/Data/UCD'
    & "$rel\bin\laplace.exe" deploy
}
& "$PSScriptRoot/install-windows-client.ps1" -Installation "$PSScriptRoot/hart-desktop-modular-client.json"

Write-Host "=== 5. Verifying zero Access Denied errors across all Laplace roots ===" -ForegroundColor Cyan
$denied = [System.Collections.Generic.List[string]]::new()
foreach ($r in $roots) {
    if (Test-Path -LiteralPath $r) {
        Get-ChildItem -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable errs | Out-Null
        foreach ($e in $errs) {
            if ($e.Exception -is [System.UnauthorizedAccessException]) {
                $denied.Add([string]$e.TargetObject)
            }
        }
    }
}
if ($denied.Count -gt 0) {
    throw "Still found $($denied.Count) unreadable path(s): $($denied -join ', ')"
}

Write-Host "All permissions repaired, stale sprawl cleaned up, and modular CLI installed." -ForegroundColor Green

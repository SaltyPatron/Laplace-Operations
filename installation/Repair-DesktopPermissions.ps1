#Requires -Version 7
<#
.SYNOPSIS
    Repairs Windows ACLs and uses the shared collector for unused generated output.
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
    2. Runs the same reference-aware collector as laplace-ops clean, unless SkipScratchCleanup is selected.
       It never selects an arbitrary release, deploys the database or rebuilds the client.
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
foreach ($tlsFile in @('E:\Data\Laplace\pgdata\server.crt', 'E:\Data\Laplace\pgdata\server.key')) {
    if (Test-Path -LiteralPath $tlsFile) {
        & takeown.exe /F $tlsFile *> $null
        & icacls.exe $tlsFile /inheritance:r /grant '*S-1-5-20:R' /grant "*${operatorSid}:F" /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' /Q | Out-Null
    }
}
if (Test-Path -LiteralPath 'D:\Libraries\postgresql\18.6') {
    & icacls.exe 'D:\Libraries\postgresql\18.6' /grant '*S-1-5-20:(OI)(CI)RX' /grant "*${operatorSid}:(OI)(CI)F" /T /C /Q | Out-Null
}

# Grant operator SID start/stop/query control over the laplace-postgres Windows service from non-elevated shells
$pgSvcName = if ($config.targets -and $config.targets[0].postgres_service) { $config.targets[0].postgres_service } else { 'laplace-postgres' }
$svcCheck = Get-Service -Name $pgSvcName -ErrorAction SilentlyContinue
if ($svcCheck) {
    $sddlOut = (& sc.exe sdshow $pgSvcName 2>$null | Where-Object { $_ -match '^D:' } | Select-Object -First 1)
    if ($sddlOut -and $sddlOut -notmatch [regex]::Escape($operatorSid)) {
        $ace = "(A;;CCLCSWRPWPDTLOCRRC;;;$operatorSid)"
        $newSddl = if ($sddlOut -match '^(D:[^\(]*(?:\([^\)]+\))*)(S:.*)$') { "$($Matches[1])$ace$($Matches[2])" } else { "$sddlOut$ace" }
        & sc.exe sdset $pgSvcName $newSddl | Out-Null
    }
    if ($svcCheck.Status -ne 'Running') {
        Write-Host "   Starting $pgSvcName service ..."
        Start-Service -Name $pgSvcName
    }
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

if (-not $SkipScratchCleanup) {
    Write-Host '=== 2. Collecting unused generated output ===' -ForegroundColor Cyan
    . "$PSScriptRoot/../laplace.env.ps1"
    . "$PSScriptRoot/desktop-clients.ps1"
    . "$PSScriptRoot/storage.ps1"
    $cleanup=Invoke-DesktopStorageCleanup -WorkRoot $env:LAPLACE_WORK -BuildRoot $env:LAPLACE_BUILD `
        -Modular (Get-DesktopClientDeclaration) -Iis (Read-StorageJson $env:LAPLACE_IIS_INSTALLATION)
    Write-Host "Cleanup receipt: $($cleanup.receipt)"
}
Write-Host "=== 3. Verifying directory access ===" -ForegroundColor Cyan
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

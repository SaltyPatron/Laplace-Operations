#Requires -Version 7
<# The desktop deployment behind laplace-ops. Setup owns provisioning; this
   workflow converges tuning on the existing installation and records every delivery stage. #>
[CmdletBinding()]
param([string]$SourcePath, [switch]$Plan)
$ErrorActionPreference = 'Stop'
$operations = Split-Path -Parent $PSScriptRoot
. "$operations/laplace.env.ps1"
$source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }
$installation = $env:LAPLACE_IIS_INSTALLATION
$steps = @(
    @{name='Apply and verify PostgreSQL tuning'; script="$operations/tune-pg.ps1"; arguments=@()},
    @{name='Build all components, migrate both databases, then publish IIS'; script="$source/deploy/windows/Build-IisPackage.ps1"; arguments=@('-Publish')},
    @{name='Verify application database'; script="$source/deploy/windows/Invoke-IisDatabase.ps1"; arguments=@('-Database','application','-Operation','status')},
    @{name='Verify substrate database'; script="$source/deploy/windows/Invoke-IisDatabase.ps1"; arguments=@('-Database','substrate','-Operation','status')},
    @{name='Verify installed desktop databases and IIS'; script="$PSScriptRoot/Verify-DesktopDatabases.ps1"; arguments=@()}
)
Write-Host 'Laplace desktop deployment' -ForegroundColor Cyan
Write-Host "Source: $source"
Write-Host "Installation: $installation"
if ($Plan) {
    for ($i=0; $i -lt $steps.Count; $i++) {
        Write-Host "[$($i+1)/$($steps.Count)] $($steps[$i].name)"
        Write-Host ('  pwsh -NoProfile -File "'+$steps[$i].script+'" '+($steps[$i].arguments -join ' '))
    }
    Write-Host 'Plan only. Installation access and live checks have not run.'
    exit 0
}

$receiptPath = $null
$result = [ordered]@{
    operation='deploy'; target='desktop'; source=$source
    identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    started_utc=[DateTime]::UtcNow.ToString('o'); status='failed'; steps=@()
}
$warnings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$record = $null
try {
    if (-not (Test-Path -LiteralPath "$source/deploy/windows/Build-IisPackage.ps1" -PathType Leaf)) {
        throw "SourcePath does not name the Laplace application checkout: $source"
    }
    if (-not $installation) {
        throw 'No IIS installation is declared. Run host setup first; setup.ps1 prepares development inputs and Install-IisRuntime.ps1 installs IIS.'
    }
    . "$source/deploy/windows/iis-runtime.ps1"
    try { $config = Read-IisInstallation $installation }
    catch [UnauthorizedAccessException] {
        throw "Cannot read $installation as $($result.identity). Run this command as the enrolled Windows operator. Host setup owns directory permissions; publication does not change account identities or ACLs."
    }
    $result.origin = $config.origin
    $revision = & git -c "safe.directory=$source" -C $source rev-parse HEAD
    if ($LASTEXITCODE) { throw 'Cannot identify the application source revision.' }
    $result.source_revision = "$revision".Trim()
    $dirty = @(& git -c "safe.directory=$source" -C $source status --porcelain --untracked-files=no)
    if ($LASTEXITCODE) { throw 'Cannot inspect application source changes.' }
    $result.modified_source = $dirty
    if ($dirty.Count) { Write-Host "Including $($dirty.Count) modified tracked files; the published package will have its own content hash." -ForegroundColor Yellow }

    # Load the declared toolchain rather than reconstructing a developer PATH.
    $developerShell = if ($env:LAPLACE_DEVSHELL) { $env:LAPLACE_DEVSHELL } else { "$operations/toolchain/windows/devshell.ps1" }
    . $developerShell
    $missing = @('pwsh','git','dotnet','npm','cmake','ninja','icx' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count) {
        throw "Developer setup is incomplete: $($missing -join ', '). Use setup.ps1 packages report; laplace-ops prepare owns locked development inputs."
    }
    $run = Join-Path $env:LAPLACE_WORK ('operations/desktop-deploy-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
    $null = New-Item -ItemType Directory -Path $run
    $receiptPath = Join-Path $run 'receipt.json'
    for ($i=0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        $log = Join-Path $run ('{0:D2}.log' -f ($i+1))
        $record = [ordered]@{name=$step.name; status='running'; started_utc=[DateTime]::UtcNow.ToString('o'); log=$log; exit_code=$null}
        $result.steps += $record
        Write-Host "`n[$($i+1)/$($steps.Count)] $($step.name)" -ForegroundColor Cyan
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $script = $step.script
        $stepArguments = $step.arguments
        & pwsh -NoProfile -File $script @stepArguments 2>&1 |
            ForEach-Object {
                $line = "$_"
                if ($line -match '(?i)\bwarning (?:CS|CA)\d+\b|^npm warn\b|^WARNING:') { $null = $warnings.Add($line) }
                $_
            } | Tee-Object -FilePath $log | Out-Host
        $exitCode = $LASTEXITCODE
        $clock.Stop()
        $record.finished_utc = [DateTime]::UtcNow.ToString('o')
        $record.seconds = [math]::Round($clock.Elapsed.TotalSeconds,2)
        $record.exit_code = $exitCode
        if ($exitCode -ne 0) {
            $record.status = 'failed'
            throw "$($step.name) failed (exit $exitCode). Log: $log"
        }
        $record.status = 'passed'
        Write-Host "Completed in $($record.seconds)s." -ForegroundColor Green
    }
    $active = Get-Content -LiteralPath (Join-Path $config.directory 'web/active.json') -Raw | ConvertFrom-Json
    $result.release = $active.revision
    $result.status = 'passed'
} catch {
    $result.error = $_.Exception.Message
    if ($record -and $record.status -eq 'running') {
        $clock.Stop()
        $record.status = 'failed'
        $record.finished_utc = [DateTime]::UtcNow.ToString('o')
        $record.seconds = [math]::Round($clock.Elapsed.TotalSeconds,2)
    }
    Write-Host "`nDesktop deployment failed: $($result.error)" -ForegroundColor Red
    if ($receiptPath) { Write-Host 'Deployment has not passed all stages. See the receipt for completed and failed work.' }
    else { Write-Host 'Preflight failed; no build, publication or migration stages ran.' }
} finally {
    $result.finished_utc = [DateTime]::UtcNow.ToString('o')
    $result.warnings = @($warnings | Sort-Object)
    if ($receiptPath) {
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath
        Write-Host "Deployment receipt: $receiptPath"
    }
}
if ($result.status -ne 'passed') { exit 1 }
Write-Host "`nDesktop deployment complete: $($result.origin)" -ForegroundColor Green
Write-Host "Release: $($result.release)"
Write-Host "Source: $($result.source_revision)"
Write-Host "$($warnings.Count) distinct warning lines recorded; full output is retained in the stage logs."
exit 0

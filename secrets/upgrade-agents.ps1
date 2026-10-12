#Requires -Version 7
param([Parameter(Mandatory)][string]$Installation, [switch]$Check)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$c = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Installation)) | ConvertFrom-Json
if ($env:COMPUTERNAME -ine $c.host) { throw "This declaration is for $($c.host)." }
if ((Get-FileHash -LiteralPath $c.executable -Algorithm SHA256).Hash -ine $c.sha256) { throw 'OpenBao source digest mismatch.' }
$version = (& $c.executable version | Out-String).Trim()
if ($LASTEXITCODE -or $version -notmatch ('^OpenBao v'+[regex]::Escape($c.version)+'\s')) { throw 'OpenBao source version mismatch.' }
if ([version]$c.version -lt [version]'2.7.1') { throw 'OpenBao 2.7.0 has an unbounded renewal retry defect; select 2.7.1 or newer.' }
$plans = foreach ($agent in $c.agents) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($agent.service)'"
    $expected = '"'+$agent.executable+'" agent -config="'+$agent.configuration+'"'
    if (-not $svc -or $svc.PathName -ine $expected) { throw "Unexpected service command for $($agent.service); no service changed." }
    if ($svc.StartName -ne 'LocalSystem') { throw "Unexpected identity for $($agent.service)." }
    [pscustomobject]@{agent=$agent; service=$svc}
}
if ($Check) {
    [pscustomobject]@{host=$c.host;source_version=$version;services=@($plans.agent.service);mode='metadata preflight; protected binaries require administrator setup'} | ConvertTo-Json
    return
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run setup.ps1 secrets-agents in administrator PowerShell; it updates the declared Windows services.' }
# Complete every protected-file preflight before stopping either workload agent.
foreach ($plan in $plans) {
    foreach ($path in @($plan.agent.executable,$plan.agent.configuration,$plan.agent.secret_id)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "Required installed agent file missing: $path" }
    }
}
$began = [DateTimeOffset]::UtcNow
$receipt = [ordered]@{host=$c.host;began_utc=$began.ToString('o');source_version=$version;sha256=$c.sha256;status='started';agents=@()}
New-Item -ItemType Directory -Force -Path $c.receipt_directory | Out-Null
$receiptPath = Join-Path $c.receipt_directory ($began.ToString('yyyyMMddTHHmmssfffffffZ')+'.json')
function Save-Receipt { [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8)) }
Save-Receipt
try {
    foreach ($plan in $plans) {
        $a = $plan.agent
        $oldVersion = (& $a.executable version | Out-String).Trim()
        $oldHash = (Get-FileHash -LiteralPath $a.executable -Algorithm SHA256).Hash
        $result = [ordered]@{service=$a.service;previous_version=$oldVersion;changed=($oldHash -ine $c.sha256);status='updating'}
        $receipt.agents += $result
        Save-Receipt
        Stop-Service -Name $a.service
        (Get-Service -Name $a.service).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
        if ($result.changed) {
            $backup = $a.executable+'.'+$oldHash.ToLowerInvariant()+'.previous'
            if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $a.executable -Destination $backup }
            # The installed private directory supplies its existing SYSTEM/Administrators ACL.
            Copy-Item -LiteralPath $c.executable -Destination $a.executable -Force
        }
        if ((Get-FileHash -LiteralPath $a.executable -Algorithm SHA256).Hash -ine $c.sha256) { throw "Installed digest mismatch: $($a.service)" }
        $result.restart_utc = [DateTimeOffset]::UtcNow.ToString('o')
        Start-Service -Name $a.service
        $result.status = 'started; awaiting authenticated render'
        Save-Receipt
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(90)
    do {
        $pending = 0
        foreach ($result in $receipt.agents) {
            if ($result.status -eq 'passed') { continue }
            $a = @($c.agents | Where-Object service -eq $result.service)[0]
            if ((Get-Service -Name $a.service).Status -ne 'Running') { throw "Credential agent stopped: $($a.service)" }
            if (Test-Path -LiteralPath $a.render_receipt) {
                try {
                    $render = [IO.File]::ReadAllText($a.render_receipt) | ConvertFrom-Json
                    if ([DateTimeOffset]$render.rendered_utc -ge [DateTimeOffset]$result.restart_utc) {
                        $result.rendered_utc=$render.rendered_utc; $result.status='passed'; continue
                    }
                } catch { # An atomic render may still be in progress; the deadline remains enforced.
                }
            }
            $pending++
        }
        if ($pending -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if ($pending) { throw 'Updated agent did not produce a fresh authenticated render within 90 seconds; inspect its existing private log. The defective executable was not restarted.' }
    $receipt.status='passed'; Save-Receipt
    Write-Host "OpenBao agents upgraded and authenticated; receipt: $receiptPath"
} catch {
    $receipt.status='failed'; $receipt.error=$_.Exception.Message; Save-Receipt
    throw
}

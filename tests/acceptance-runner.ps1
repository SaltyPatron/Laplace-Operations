#Requires -Version 7
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ('laplace-acceptance-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
$verifier = Join-Path $PSScriptRoot '../acceptance/verify.ps1'
$manifest = Join-Path $work 'criteria.json'
$platform = if ($IsWindows) { 'windows' } else { 'linux' }
$other = if ($IsWindows) { 'linux' } else { 'windows' }
$cases = @(
    @{ id='pass'; platform='any'; scratch=$true; argv=@('pwsh','-NoProfile','-Command','[IO.File]::WriteAllText((Join-Path $env:LAPLACE_ACCEPTANCE_WORK payload.txt),"fixture"); exit 0'); evidence='fixture'; timeout_seconds=10 },
    @{ id='fail'; platform='any'; scratch=$true; argv=@('pwsh','-NoProfile','-Command','exit 7'); evidence='fixture'; timeout_seconds=10 },
    @{ id='missing'; platform='any'; scratch=$true; argv=@('laplace-missing-fixture-command'); evidence='fixture'; timeout_seconds=10 },
    @{ id='pending'; platform='any'; argv=$null; evidence='not implemented' },
    @{ id='other'; platform=$other; argv=@('pwsh','-NoProfile','-Command','exit 0'); evidence='other platform'; timeout_seconds=10 },
    @{ id='timeout'; platform=$platform; scratch=$true; argv=@('pwsh','-NoProfile','-Command','Start-Sleep -Seconds 10'); evidence='fixture'; timeout_seconds=1 }
)
@{ schema_version=1; tracker='fixture'; criteria=@(@{
    id='FIXTURE'; owner='test'; outcome='Exercise failure reporting'; depends_on=@(); checks=$cases
}) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest
function Assert($condition, $message) { if (-not $condition) { throw $message } }
foreach ($case in @(@('pass',0,'passed'), @('fail',1,'failed'), @('missing',1,'failed'),
                    @('pending',2,'not_implemented'), @('other',2,'wrong_platform'), @('timeout',1,'timed_out'))) {
    $receipt = Join-Path $work "$($case[0]).json"
    & pwsh -NoProfile -File $verifier -Manifest $manifest -Check $case[0] -Output $receipt *> $null
    Assert ($LASTEXITCODE -eq $case[1]) "$($case[0]): wrong process exit $LASTEXITCODE"
    $result = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json -Depth 20
    $selected = @($result.checks | Where-Object selected)
    Assert ($selected.Count -eq 1 -and $selected[0].status -eq $case[2]) "$($case[0]): wrong evidence status"
    Assert ($result.installation_verdict -eq 'incomplete') 'A scoped check claimed installation acceptance'
    Assert ($result.source_revision -match '^[0-9a-f]{40}$') 'Receipt lost its source revision'
    if ($case[0] -in 'pass','fail','missing','timeout') {
        Assert ($selected[0].scratch_removed -and -not (Test-Path (Join-Path $work ($case[0]+'-scratch')))) "$($case[0]): runner left transient payload behind"
    }
}
$existing = Join-Path $work 'pass.json'
$hash = (Get-FileHash $existing).Hash
& pwsh -NoProfile -File $verifier -Manifest $manifest -Check pass -Output $existing *> $null
Assert ($LASTEXITCODE -ne 0 -and (Get-FileHash $existing).Hash -eq $hash) 'Existing evidence was replaced'
& pwsh -NoProfile -File $verifier -Manifest $manifest -Check unknown -Output (Join-Path $work 'unknown.json') *> $null
Assert ($LASTEXITCODE -ne 0) 'Unknown check accepted'
'Acceptance receipt failure boundaries and owned scratch cleanup: passed'
} finally {
    . "$PSScriptRoot/../installation/storage.ps1"
    Assert-StorageTree $work ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
}

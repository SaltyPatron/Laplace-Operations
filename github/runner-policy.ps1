#Requires -Version 7
[CmdletBinding()]
param([switch]$Apply, [string]$Policy = "$PSScriptRoot/runner-policy.json", [string]$Output)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../secrets/process.ps1"
if (-not $Output) {
    . "$PSScriptRoot/../laplace.env.ps1"
    $Output=Join-Path $env:LAPLACE_WORK ('operations/fork-policy-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '.json')
}
if (Test-Path -LiteralPath $Output) { throw 'Use a new receipt path; previous policy evidence is preserved.' }
$config=Get-Content -LiteralPath $Policy -Raw | ConvertFrom-Json
if ($config.owner -notmatch '^[a-zA-Z0-9-]+$' -or $config.fork_pr_approval -ne 'all_external_contributors') { throw 'Invalid runner policy.' }
foreach ($name in $config.repositories) { if ($name -notmatch '^Laplace[a-zA-Z0-9_-]*$') { throw 'Invalid repository name.' } }
$receipt=[ordered]@{checked_utc=[DateTime]::UtcNow.ToString('o');revision=(Invoke-Program git @('-C',"$PSScriptRoot/..",'rev-parse','HEAD')).Trim();
    apply=[bool]$Apply;scope='Fork workflow approval configuration, not build isolation';repositories=@();passed=$false}
try {
    foreach ($name in $config.repositories) {
        $repository="$($config.owner)/$name"
        $endpoint="repos/$repository/actions/permissions/fork-pr-contributor-approval"
        $before=Invoke-Program gh @('api',$endpoint) | ConvertFrom-Json
        if ($Apply -and $before.approval_policy -ne $config.fork_pr_approval) {
            $null=Invoke-Program gh @('api','--method','PUT',$endpoint,'-f',"approval_policy=$($config.fork_pr_approval)")
        }
        $after=Invoke-Program gh @('api',$endpoint) | ConvertFrom-Json
        $runners=Invoke-Program gh @('api',"repos/$repository/actions/runners") | ConvertFrom-Json
        $receipt.repositories+=@{repository=$repository;before=$before.approval_policy;after=$after.approval_policy;
            runner_count=$runners.total_count;passed=($after.approval_policy -eq $config.fork_pr_approval)}
        Write-Host "${repository}: $($after.approval_policy) ($($runners.total_count) registered runners)"
    }
    $receipt.passed=@($receipt.repositories | Where-Object { -not $_.passed }).Count -eq 0
    if (-not $receipt.passed) { throw 'Fork workflow approval differs from the declared policy.' }
} finally {
    $receipt.completed_utc=[DateTime]::UtcNow.ToString('o')
    [void](New-Item -ItemType Directory -Path (Split-Path ([IO.Path]::GetFullPath($Output))) -Force)
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Output
    Write-Host "Policy evidence: $Output"
}

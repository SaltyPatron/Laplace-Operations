#Requires -Version 7
# Continue only the unfinished delivery stages after the recorded IIS activation.
$ErrorActionPreference='Stop'
$workspace='E:\Repositories\Laplace'
$audit=$PSScriptRoot
$operations=Join-Path $workspace 'Laplace-Operations'
$initial=Get-Content -LiteralPath (Join-Path $audit 'desktop-owner-initial-deployment.json') -Raw|ConvertFrom-Json
$access=Get-Content -LiteralPath (Join-Path $audit 'desktop-owner-completion.json') -Raw|ConvertFrom-Json
if($access.repaired.Count -ne 23 -or $initial.steps[0].status -ne 'passed' -or $initial.steps[1].status -ne 'passed'){
    throw 'The privileged preparation and IIS activation must already have passed.'
}
$uci=Get-Content -LiteralPath (Join-Path $audit 'desktop-uci-installed-source.json') -Raw|ConvertFrom-Json
$uciRepository=Join-Path $workspace 'Laplace-UCI'
$uciBefore=$uci.product_version.Split('+')[-1]
$uciChanges=@(& git -C $uciRepository diff --name-only $uciBefore HEAD)
if($LASTEXITCODE -or @($uciChanges|Where-Object {$_ -notin @('.github/workflows/build.yml','README.md','configuration.md')}).Count){
    throw 'The serving UCI connector differs from current runtime source; it needs a separate publication.'
}
$receipt=[ordered]@{status='running';started_utc=[DateTime]::UtcNow.ToString('o');
    prior_deployment='desktop-owner-initial-deployment.json';extra_uac_prompts=0;
    uci_runtime_source_equivalent=$true;uci_nonruntime_changes=$uciChanges;steps=@()}
$receiptPath=Join-Path $audit 'desktop-resume-completion.json'
function Save {$receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $receiptPath -Encoding utf8}
Save
try{
    $steps=@(
        @{name='modular';script=(Join-Path $operations 'laplace.ps1');arguments=@('deploy','-Target','desktop','-Components','modular','-SourcePath',(Join-Path $workspace 'Laplace'))},
        @{name='uci-binding';script=(Join-Path $operations 'installation/desktop-uci.ps1');arguments=@()},
        @{name='all-installed-readback';script=(Join-Path $operations 'installation/Verify-DesktopDatabases.ps1');arguments=@('-Scope','all')}
    )
    foreach($step in $steps){
        $entry=[ordered]@{name=$step.name;status='running';started_utc=[DateTime]::UtcNow.ToString('o')}
        $receipt.steps+=@($entry);Save
        $log=Join-Path $audit ('desktop-resume-'+$step.name+'.log')
        & pwsh -NoProfile -File $step.script @($step.arguments) 2>&1|Tee-Object -FilePath $log|Out-Host
        if($LASTEXITCODE){throw "Desktop resume stage $($step.name) failed: $LASTEXITCODE"}
        $entry.status='passed';$entry.finished_utc=[DateTime]::UtcNow.ToString('o');$entry.log=$log;Save
    }
    $receipt.status='passed';$receipt.completed_utc=[DateTime]::UtcNow.ToString('o');Save
}catch{
    $receipt.status='failed';$receipt.error=$_.Exception.Message;Save
    throw
}

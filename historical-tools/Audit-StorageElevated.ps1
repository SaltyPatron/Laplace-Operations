$ErrorActionPreference='Stop'
$audit='E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z'
try{
 . 'E:\Repositories\Laplace\Laplace-Operations\laplace.env.ps1'
 . 'E:\Repositories\Laplace\Laplace-Operations\installation\desktop-clients.ps1'
 . 'E:\Repositories\Laplace\Laplace-Operations\installation\storage.ps1'
 $modular=Get-DesktopClientDeclaration
 $iis=Read-StorageJson $env:LAPLACE_IIS_INSTALLATION
 $arguments=@{WorkRoot=$env:LAPLACE_WORK;BuildRoot=$env:LAPLACE_BUILD;Modular=$modular;Iis=$iis}
 $plan=Get-DesktopStoragePlan @arguments
 $plan|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $audit 'storage-elevated-plan.json')
 @{status='passed';entries=@($plan.entries).Count;retire=@($plan.entries|Where-Object retire).Count;finished_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $audit 'storage-elevated-result.json')
}catch{
 @{status='failed';error=$_.Exception.Message;stack=$_.ScriptStackTrace;finished_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $audit 'storage-elevated-result.json')
 exit 1
}

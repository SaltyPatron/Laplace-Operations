$ErrorActionPreference='Stop'
$audit='E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z'
try{
 . 'E:\Repositories\Laplace\Laplace-Operations\laplace.env.ps1'
 . 'E:\Repositories\Laplace\Laplace-Operations\installation\desktop-clients.ps1'
 . 'E:\Repositories\Laplace\Laplace-Operations\installation\storage.ps1'
 $modular=Get-DesktopClientDeclaration
 $iis=Read-StorageJson $env:LAPLACE_IIS_INSTALLATION
 $arguments=@{WorkRoot=$env:LAPLACE_WORK;BuildRoot=$env:LAPLACE_BUILD;Modular=$modular;Iis=$iis}
 $reviewed=Get-Content -LiteralPath (Join-Path $audit 'storage-elevated-plan.json') -Raw|ConvertFrom-Json
 $approved=@($reviewed.entries|Where-Object retire|ForEach-Object {[IO.Path]::GetFullPath($_.path)})
 $current=Get-DesktopStoragePlan @arguments
 foreach($entry in @($current.entries|Where-Object retire)){
  $target=[IO.Path]::GetFullPath($entry.path)
  if($target -notin $approved){throw "Cleanup plan changed before execution: $target"}
  if($target -notmatch '^E:\\Data\\Laplace\\(?:services\\laplace\\releases|work\\artifacts|work\\operations)\\'){throw "Cleanup path outside reviewed runtime roots: $target"}
 }
 $selectionPaths=@($env:LAPLACE_IIS_INSTALLATION,$modular.installed_config,(Join-Path $iis.directory 'web/active.json'),(Join-Path $iis.directory 'web/web.config'))
 $before=@{}
 foreach($path in $selectionPaths){if(Test-Path -LiteralPath $path -PathType Leaf){$before[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}}
 $state=Invoke-DesktopStorageCleanup @arguments
 $state|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $audit 'storage-cleanup.json')
 foreach($path in $before.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $before[$path]){throw "Installed selection changed during cleanup: $path"}}
 $after=Get-DesktopStoragePlan @arguments
 $after|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $audit 'storage-post-cleanup-plan.json')
 @{status='passed';receipt=$state.receipt;removed=@($state.removed).Count;remaining_retirable=@($after.entries|Where-Object retire).Count;selection_hashes=$before;database_cleanup=$state.database_cleanup;finished_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $audit 'storage-cleanup-result.json')
}catch{
 @{status='failed';error=$_.Exception.Message;stack=$_.ScriptStackTrace;finished_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $audit 'storage-cleanup-result.json')
 exit 1
}

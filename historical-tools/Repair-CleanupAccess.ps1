$ErrorActionPreference='Stop'
$audit='E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z'
$targets=@(
'E:\Repositories\Laplace\.build\.tmp\25216000000020782',
'E:\Repositories\Laplace\.build\.tmp\32384000000136332',
'E:\Repositories\Laplace\.build\.tmp\33308000000067652',
'E:\Repositories\Laplace\.build\.tmp\9624000000078942',
'E:\Data\Laplace\work\artifacts\windows-components\api\050426c8e8620f0f2cb48a1b967e05344afd8c7cb27c03e51198da84f0577b67'
)
$results=@()
try{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 if(-not $admin){throw 'This repair requires an elevated Windows administrator token'}
 foreach($target in $targets){
  $item=Get-Item -LiteralPath $target -Force -ErrorAction Stop
  if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Target must be a regular directory: $target"}
  $before=Get-Acl -LiteralPath $target -ErrorAction Stop
  $entry=@{path=$target;owner_before=$before.Owner;sddl_before=$before.Sddl;status='prepared'}
  $results+=$entry
  $results|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $audit 'acl-repair.json')
  $sidGrant='*S-1-5-21-1955383224-1799969050-1119319971-1001:(OI)(CI)(F)'
  $output=& icacls.exe $target /grant $sidGrant /T /C 2>&1
  $entry.command_output=@($output|ForEach-Object {$_ | Out-String})
  $entry.exit_code=$LASTEXITCODE
  if($LASTEXITCODE -ne 0){throw "ACL grant failed for $target : $($output -join ' ')"}
  $after=Get-Acl -LiteralPath $target -ErrorAction Stop
  $entry.owner_after=$after.Owner;$entry.sddl_after=$after.Sddl;$entry.status='repaired'
  $results|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $audit 'acl-repair.json')
 }
 @{status='passed';completed_utc=[DateTime]::UtcNow.ToString('o');directories=$targets}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $audit 'acl-repair-result.json')
}catch{
 @{status='failed';error=$_.Exception.Message;completed_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $audit 'acl-repair-result.json')
 exit 1
}

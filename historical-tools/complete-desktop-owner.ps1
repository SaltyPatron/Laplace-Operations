#Requires -Version 7
[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$workspace='E:\Repositories\Laplace'
$audit=$PSScriptRoot
$operations=Join-Path $workspace 'Laplace-Operations'
$source=Join-Path $workspace 'Laplace'
$operator=Get-Content -LiteralPath (Join-Path $operations 'installation/hart-desktop-operator.json') -Raw | ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.User.Value -ne $operator.windows_sid){throw 'Use the declared Windows operator identity.'}
$packageReceipt=Get-Content -LiteralPath (Join-Path $audit 'desktop-prepared-package.json') -Raw | ConvertFrom-Json
. (Join-Path $source 'deploy/windows/iis-runtime.ps1')
$expectedPackage='E:\Data\Laplace\work\artifacts\iis-packages\f8ffc7d5e404b80cf2200e58eea4b04be83308b79e97d3db15584e6ad09f1d76'
if([IO.Path]::GetFullPath($packageReceipt.package) -cne $expectedPackage){throw 'The reviewed package path changed.'}
$package=Test-IisPackage $packageReceipt.package
$manifestHash=(Get-FileHash -LiteralPath (Join-Path $expectedPackage 'iis-package.json') -Algorithm SHA256).Hash
if($package.revision -ne '60f039aa16ac23c060901d1a9bb056838cc8dd660f9d1556ece77c89e899c863' -or
   $package.source_revision -ne '5e78670e18c11c0292c6908a58cc8517e8760057' -or
   $manifestHash -ne '0945170449cd018b3db9049af1a8bda690521e704908f08edb7c4bd115947255'){
    throw 'The reviewed package manifest changed.'
}
foreach($name in 'Laplace','Laplace-Native','Laplace-Engine','Laplace-MCP','Laplace-postgres','Laplace-Operations'){
    $repository=Join-Path $workspace $name
    $branch=(& git -C $repository branch --show-current).Trim()
    $head=(& git -C $repository rev-parse HEAD).Trim()
    $remote=(& git -C $repository rev-parse origin/main).Trim()
    $dirty=@(& git -C $repository status --porcelain --untracked-files=no)
    if($LASTEXITCODE -or $branch -ne 'main' -or $head -ne $remote -or $dirty.Count){throw "Source is not verified clean main: $name"}
}
$runtimeChanges=@(& git -C $source diff --name-only $package.source_revision HEAD -- engine extension app web scripts/win deploy)
if($LASTEXITCODE -or $runtimeChanges.Count){throw 'Runtime source changed after package verification.'}
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
$administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if($PreflightOnly){
    [ordered]@{checked_utc=[DateTime]::UtcNow.ToString('o');status='preflight-passed';identity=$identity.Name;
        administrator_token=$administrator;package=$expectedPackage;release=$package.revision;
        manifest_sha256=$manifestHash.ToLowerInvariant();verified_files=$package.files.Count;
        runtime_source_matches_main=$true;administrator_operation_launched=$false} | ConvertTo-Json
    exit 0
}
if(-not $administrator){throw 'Desktop activation requires an Administrator token; no elevation was requested by this script.'}
$receipt=[ordered]@{status='running';started_utc=[DateTime]::UtcNow.ToString('o');identity=$identity.Name;package=$packageReceipt.package;stage='repair-enrolled-operator-access';repaired=@()}
$receiptPath=Join-Path $audit 'desktop-owner-completion.json'
function Save { $receipt | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $receiptPath -Encoding utf8 }
Save
try {
    $store='E:\Data\Laplace\work\artifacts\windows-components'
    $targets=@(Get-Content -LiteralPath (Join-Path $audit 'desktop-unreadable-component-directories.json') -Raw | ConvertFrom-Json)
    foreach($target in $targets){
        $path=[IO.Path]::GetFullPath($target.path)
        if($path -notmatch ('^'+[regex]::Escape($store)+'\\(?:api|cli|uci|migrations)\\[a-f0-9]{64}$')){throw 'Access repair target escaped the reviewed component store.'}
        $items=@(Get-Item -LiteralPath $path)+@(Get-ChildItem -LiteralPath $path -Recurse -Force)
        if(@($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw "A component redirects outside its store: $path"}
        foreach($item in $items){
            $acl=Get-Acl -LiteralPath $item.FullName
            foreach($rule in @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))){
                if($rule.IdentityReference.Value -eq $operator.windows_sid -and $rule.AccessControlType -eq 'Deny'){$null=$acl.RemoveAccessRuleSpecific($rule)}
            }
            $flags=if($item.PSIsContainer){'ContainerInherit,ObjectInherit'}else{'None'}
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($operator.windows_sid),'FullControl',$flags,'None','Allow'))
            Set-Acl -LiteralPath $item.FullName -AclObject $acl
        }
        $receipt.repaired+=@{path=$path;items=$items.Count};Save
    }
    $receipt.stage='standard-desktop-owner-deployment';Save
    & pwsh -NoProfile -File (Join-Path $operations 'laplace.ps1') deploy -Target desktop -Components all -SourcePath $source 2>&1 |
        Tee-Object -FilePath (Join-Path $audit 'desktop-owner-deployment.log') | Out-Host
    if($LASTEXITCODE){throw "Desktop owner deployment failed: $LASTEXITCODE"}
    $receipt.status='passed';$receipt.stage='activated-and-verified';$receipt.completed_utc=[DateTime]::UtcNow.ToString('o');Save
}catch{
    $receipt.status='failed';$receipt.error=$_.Exception.Message;Save
    throw
}

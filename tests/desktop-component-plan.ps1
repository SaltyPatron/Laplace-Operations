$ErrorActionPreference='Stop'
$env:COMPUTERNAME='HART-DESKTOP'
$entry=Join-Path $PSScriptRoot '../laplace.ps1'
function Plan([string]$Components,[switch]$Force){
    $args=@('-NoProfile','-File',$entry,'deploy','desktop','-Components',$Components,'-Plan')
    if($Force){$args+='-Force'}
    $lines=@(& pwsh @args 2>&1)
    if($LASTEXITCODE){throw ($lines -join "`n")}
    $lines -join "`n"
}
$web=Plan web
if($web -match 'tune-pg|install-windows-client|Invoke-IisDatabase|ComponentSelection (?!web\b)'){
    throw 'Web delivery selected unrelated modular, PostgreSQL or migration work.'
}
$api=Plan 'api,cli'
if($api -notmatch 'Components: api, cli, web' -or $api -match 'tune-pg|install-windows-client'){
    throw 'API/CLI delivery did not select its frontend dependency independently.'
}
$modular=Plan modular -Force
if($modular -notmatch 'install-windows-client.*-Force' -or $modular -match 'Build-IisPackage|tune-pg'){
    throw 'Modular-only or explicit-force selection was lost.'
}
$all=Plan all
if($all -notmatch 'tune-pg' -or $all -notmatch 'install-windows-client' -or $all -notmatch 'Build-IisPackage'){
    throw 'Full delivery lost a component owner.'
}
'Desktop component selection: web, API/CLI dependencies, isolated modular force and full delivery passed.'

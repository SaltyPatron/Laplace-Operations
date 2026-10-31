$ErrorActionPreference='Stop'
$env:COMPUTERNAME='HART-DESKTOP'
$entry=Join-Path $PSScriptRoot '../laplace.ps1'
function Plan([string]$Components,[switch]$Force,[string]$Package){
    $args=@('-NoProfile','-File',$entry,'deploy','desktop','-Components',$Components,'-Plan')
    if($Force){$args+='-Force'}
    if($Package){$args+=@('-Package',$Package)}
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
if($modular -notmatch 'Migrate the installed modular substrate'){
    throw 'Modular delivery selected a client without updating its substrate.'
}
if($modular -notmatch 'deploy --configure-server-cache'){
    throw 'The host installer did not explicitly select server-local cache paths.'
}
$all=Plan all
if($all -notmatch 'tune-pg' -or $all -notmatch 'install-windows-client' -or $all -notmatch 'Build-IisPackage'){
    throw 'Full delivery lost a component owner.'
}
if($all -notmatch 'desktop-uci.ps1.*-Publish' -or $web -match 'desktop-uci.ps1'){
    throw 'UCI connector publication must follow UCI component selection and leave web-only delivery independent.'
}
if($all.IndexOf('Migrate the installed modular substrate') -le $all.IndexOf('Build selected components, compose and activate IIS') -or
   $all.IndexOf('Package modular Native, Engine and MCP') -le $all.IndexOf('Build selected components, compose and activate IIS') -or
   $all.IndexOf('Verify selected installed components') -le $all.IndexOf('Migrate the installed modular substrate')){
    throw 'Modular database update must follow extension installation and precede installed verification.'
}
if($modular -notmatch 'install-windows-client.*-ConfigureDatabase' -or $all -notmatch 'install-windows-client.*-ConfigureDatabase'){
    throw 'The host deployment must select server-local caches before client compatibility verification.'
}
$prepared=Plan all -Package (Join-Path ([IO.Path]::GetTempPath()) 'prepared-package')
if($prepared -notmatch 'Publish-IisRuntime.ps1' -or $prepared -match 'Build-IisPackage|tune-pg|install-windows-client'){
    throw 'Prepared package activation selected a build or an unrelated installation.'
}
'Desktop component selection: web, API/CLI dependencies, isolated modular force and full delivery passed.'

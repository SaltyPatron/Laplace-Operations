#Requires -Version 7
[CmdletBinding()]
param([string]$SourcePath,[string]$Installation=$env:LAPLACE_IIS_INSTALLATION)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/../development/credentials.ps1"
if(-not $SourcePath){$SourcePath=Join-Path $env:LAPLACE_SRC 'Laplace'}
if(-not $Installation){$Installation=$env:LAPLACE_IIS_INSTALLATION}
$verifier=Join-Path $SourcePath 'deploy/windows/Verify-IisApplication.ps1'
if(-not(Test-Path -LiteralPath $verifier -PathType Leaf)){throw 'The monorepo installed-runtime verifier is absent.'}
$config=Read-DevelopmentConfig "$PSScriptRoot/../development/installation.json"
$iis=Get-Content -LiteralPath $Installation -Raw|ConvertFrom-Json
if($config.database_host -ine $iis.database.host -or $config.substrate_database -ne $iis.database.substrate_database -or
   $config.application_database -ne $iis.database.application_database){throw 'Development credentials and installed IIS databases select different targets.'}
$savedToken=$env:LAPLACE_OPERATOR_TOKEN;$savedKey=$env:LAPLACE_API_KEY;$token=$null
try{
    $token=New-DevelopmentBaoSession $config
    $path=(Get-DevelopmentSecretPaths $config)['laplace-api'] -replace '^kv/','kv/data/'
    $env:LAPLACE_OPERATOR_TOKEN=(Invoke-DevelopmentBao $config GET $path $token).data.data.operator_token
    if(-not $env:LAPLACE_OPERATOR_TOKEN){throw 'The enrolled verification credential is missing.'}
    Remove-Item Env:LAPLACE_API_KEY -ErrorAction SilentlyContinue
    & $verifier -Installation $Installation -ReceiptDirectory $env:LAPLACE_ACCEPTANCE_RESULTS
}finally{
    $env:LAPLACE_OPERATOR_TOKEN=$savedToken;$env:LAPLACE_API_KEY=$savedKey
    if($token){$null=Invoke-DevelopmentBao $config POST 'auth/token/revoke-self' $token @{}}
}

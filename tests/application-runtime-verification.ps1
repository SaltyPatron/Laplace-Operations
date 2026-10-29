#Requires -Version 7
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../secrets/application-runtime.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('runtime-owner-'+[guid]::NewGuid().ToString('N'))
try{
    $owner=Join-Path $root 'deploy/linux/runtime/application-runtime.py'
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $owner) -Force
    @'
import json,sys
assert sys.argv == ["application-runtime.py","--phase","verify","--stdout-only"]
print(json.dumps({"configuration":json.load(sys.stdin),"owner":"fixture"}))
'@ | Set-Content -LiteralPath $owner
    $config=@{host='test-host';state='private state';value="quoting ' and \ and `" remain literal"}
    $request=New-ApplicationRuntimeVerification $config $root
    if(($request.arguments[0..3] -join ',') -cne 'sudo,-n,python3,-c'){throw 'Verification requested an installation command.'}
    $python=if($IsWindows){(& py -3 -c 'import sys;print(sys.executable)')}else{(Get-Command python3).Source}
    $result=Invoke-Program $python @('-c',$request.arguments[-1]) $request.payload|ConvertFrom-Json
    if($result.owner -ne 'fixture' -or $result.configuration.value -cne $config.value){throw 'Canonical verifier source or configuration changed during transport.'}
    Remove-Item -LiteralPath $owner
    $refused=$false;try{New-ApplicationRuntimeVerification $config $root|Out-Null}catch{$refused=$true}
    if(-not $refused){throw 'Missing owner did not stop verification before SSH.'}
    'Runtime verification: canonical owner, exact arguments, literal payload, no remote installer transfer and absent-owner refusal passed.'
}finally{
    if([IO.Path]::GetDirectoryName($root) -ine [IO.Path]::GetTempPath().TrimEnd('\','/')){throw 'Invalid verification fixture cleanup root.'}
    Remove-Item -LiteralPath $root -Recurse -Force
}

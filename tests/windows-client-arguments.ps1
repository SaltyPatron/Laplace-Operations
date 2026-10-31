# Exercise the real installer wrapper against an isolated packaging process.
param([string]$Python)
$ErrorActionPreference='Stop'
if(-not $Python){$Python=(& python -c 'import sys; print(sys.executable)').Trim()}
if(-not(Test-Path -LiteralPath $Python -PathType Leaf)){throw 'Select an installed Python interpreter.'}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('laplace client argv-'+[guid]::NewGuid().ToString('N'))
$previousPython=$env:LAPLACE_TEST_PYTHON
$previousTrace=$env:LAPLACE_TEST_TRACE
try{
    foreach($name in 'installation','toolchain/windows'){$null=New-Item -ItemType Directory -Path (Join-Path $temporary $name) -Force}
    $installer=Join-Path $temporary 'installation/install-windows-client.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../installation/install-windows-client.ps1') -Destination $installer
    Set-Content -LiteralPath (Join-Path $temporary 'laplace.env.ps1') -Value ''
    Set-Content -LiteralPath (Join-Path $temporary 'toolchain/windows/devshell.ps1') -Value 'function python { $global:LASTEXITCODE=0; $env:LAPLACE_TEST_PYTHON }'
    Set-Content -LiteralPath (Join-Path $temporary 'installation/storage.ps1') -Value @'
function Enter-DesktopStorageOperation { [pscustomobject]@{fixture=$true} }
function Exit-DesktopStorageOperation { param($Operation,$Modular) }
'@
    Set-Content -LiteralPath (Join-Path $temporary 'installation/package-windows-client.py') -Value @'
import argparse,json,os,sys
from pathlib import Path
Path(os.environ['LAPLACE_TEST_TRACE']).write_text(json.dumps(sys.argv[1:]))
parser=argparse.ArgumentParser()
parser.add_argument('--installation',required=True)
parser.add_argument('--force',action='store_true')
parser.add_argument('--configure-database',action='store_true')
parser.parse_args()
sys.exit(19) # End before any real installation or user configuration write.
'@
    $declaration=Join-Path $temporary 'host declaration.json'
    @{host=$env:COMPUTERNAME}|ConvertTo-Json|Set-Content -LiteralPath $declaration
    $env:LAPLACE_TEST_PYTHON=[IO.Path]::GetFullPath($Python)
    $env:LAPLACE_TEST_TRACE=Join-Path $temporary 'arguments.json'
    foreach($force in @($false,$true)){
        foreach($configure in @($false,$true)){
            $invocation=@('-NoProfile','-File',$installer,'-Installation',$declaration)
            $expected=@('--installation',$declaration)
            if($force){$invocation+='-Force';$expected+='--force'}
            if($configure){$invocation+='-ConfigureDatabase';$expected+='--configure-database'}
            $output=@(& pwsh @invocation 2>&1)
            if(-not $LASTEXITCODE -or ($output -join "`n") -notmatch 'Modular client packaging failed'){
                throw ('The isolated packaging failure did not stop before installation: '+($output -join "`n"))
            }
            $actual=@(Get-Content -LiteralPath $env:LAPLACE_TEST_TRACE -Raw|ConvertFrom-Json)
            if(($actual|ConvertTo-Json -Compress) -cne ($expected|ConvertTo-Json -Compress)){
                throw "Packaging argument vector changed for force=$force configure=$configure : $($actual|ConvertTo-Json -Compress)"
            }
        }
    }
    'Windows installer passes complete native arguments for ordinary, force, configure and combined packaging.'
}finally{
    $env:LAPLACE_TEST_PYTHON=$previousPython
    $env:LAPLACE_TEST_TRACE=$previousTrace
    $resolved=[IO.Path]::GetFullPath($temporary)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved) -ine $parent -or [IO.Path]::GetFileName($resolved) -notmatch '^laplace client argv-[a-f0-9]{32}$'){
        throw 'Fixture cleanup escaped its temporary directory.'
    }
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

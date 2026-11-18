#Requires -Version 7
<#
  Laplace-Native as the CMake package LaplaceNative (package.ps1 laplace-native); the last line of output is the prefix.
    pwsh -File native-package.ps1 [native-source]     default $env:LAPLACE_SRC\Laplace-Native
#>
param([string]$Native = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if (-not $Native) { $Native = Join-Path $env:LAPLACE_SRC 'Laplace-Native' }
& "$PSScriptRoot\package.ps1" laplace-native $Native 'LAPLACE_NATIVE_TESTS=OFF'
exit $LASTEXITCODE

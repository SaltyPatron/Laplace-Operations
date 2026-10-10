<#
  The developer shell on Windows (LAPLACE_DEVSHELL): dot-source it and this PowerShell has the compilers and the
  build tools the dependency and Laplace builds use. Nothing of it is written by hand and nothing is set outside the
  process (Operations#2: no toolchain on the global PATH).

    . toolchain\windows\devshell.ps1

  What it loads, in this order, each found on the machine and none named by a fixed path:
    Visual Studio's x64 environment    the newest installation with the C++ tools (vswhere), or LAPLACE_VS: its
                                       installation directory. The linker, the headers and libraries, the Windows SDK.
    oneAPI                             where its installer put it (ONEAPI_ROOT, or above the compiler it registered for
                                       the machine), or LAPLACE_ONEAPI: its oneapi-vars.bat. icx, icpx, the MKL and OpenMP
                                       runtimes.
    the manifest's tools               every row of dependencies.tsv of kind tool that setup.ps1 deps unpacked under
                                       LAPLACE_DEPS (Strawberry Perl, winflexbison, NASM): its directories of programs.
  A part that is not on the machine is said, and the rest is loaded: setup.ps1 packages reports what is missing.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\laplace.env.ps1"

function Import-BatchEnvironment([string]$Batch, [string]$Arguments = '') {     # what a batch file sets, into this process
    $mark = '---laplace-devshell-environment---'
    $run = Join-Path ([IO.Path]::GetTempPath()) "laplace-devshell-$PID.cmd"
    Set-Content -LiteralPath $run -Encoding Ascii -Value "@echo off`r`ncall `"$Batch`" $Arguments >nul 2>&1`r`necho $mark`r`nset"
    try { $out = [string[]](& cmd.exe /d /c "`"$run`"") } finally { Remove-Item -LiteralPath $run -ErrorAction SilentlyContinue }
    $at = [Array]::IndexOf($out, $mark); if ($at -lt 0) { return $false }
    foreach ($line in $out[($at + 1)..($out.Count - 1)]) { $i = $line.IndexOf('='); if ($i -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $i), $line.Substring($i + 1), 'Process') } }
    $true
}

$said = [Collections.Generic.List[string]]::new()
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vs = $env:LAPLACE_VS
    if (-not $vs) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path $vswhere) { $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1 }
    }
    $vcvars = if ($vs) { Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat' }
    if ($vcvars -and (Test-Path $vcvars)) { [void](Import-BatchEnvironment $vcvars); if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { $said.Add("Visual Studio: $vcvars did not give cl") } }
    else { $said.Add('Visual Studio: no installation with the C++ tools (vswhere), and LAPLACE_VS names none') }
}
if (-not (Get-Command icx.exe -ErrorAction SilentlyContinue)) {
    # where the installer put it: ONEAPI_ROOT when it set one, else above the compiler it registered for the machine
    # (IFORT_COMPILER<yy> or ICPP_COMPILER<yy>: <oneAPI>\compiler\<version>\), the newest of them
    $oneapi = if ($env:LAPLACE_ONEAPI) { $env:LAPLACE_ONEAPI } else { $env:ONEAPI_ROOT }
    if (-not $oneapi) {
        $reg = [Environment]::GetEnvironmentVariables('Machine')
        $newest = $reg.Keys | Where-Object { $_ -match '^(IFORT|ICPP)_COMPILER\d+$' } | Sort-Object { [int]($_ -replace '\D') } | Select-Object -Last 1
        $d = if ($newest) { ([string]$reg[$newest]).TrimEnd('\') }
        while ($d -and -not $oneapi) { if (Test-Path (Join-Path $d 'setvars.bat')) { $oneapi = $d } else { $d = Split-Path $d } }
    }
    # the unified layout's script (<oneAPI>\<version>\oneapi-vars.bat, the newest version) where there is one, else the
    # component layout's setvars.bat. A component's own script failing (a profiler's) is not the compiler's: what
    # counts is icx afterwards.
    $setvars = if ($oneapi) {
        $unified = Get-ChildItem -LiteralPath $oneapi -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+)+$' -and (Test-Path (Join-Path $_.FullName 'oneapi-vars.bat')) } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
        if ($unified) { Join-Path $unified.FullName 'oneapi-vars.bat' } else { Join-Path $oneapi 'setvars.bat' }
    }
    if ($setvars -and (Test-Path $setvars)) { [void](Import-BatchEnvironment $setvars 'intel64'); if (-not (Get-Command icx.exe -ErrorAction SilentlyContinue)) { $said.Add("oneAPI: $setvars did not give icx") } }
    else { $said.Add('oneAPI: no installation found (ONEAPI_ROOT, the compiler the installer registered), and LAPLACE_ONEAPI names none') }
}
# the manifest's tools: the directories under each unpacked tool that hold its programs
$tools = foreach ($line in Get-Content (Join-Path $PSScriptRoot '..\..\dependencies.tsv')) {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    $f = $line -split "`t"; if ($f.Count -lt 9 -or $f[2] -ne 'tool' -or $f[6] -ne 'unpack' -or ($f[8] -split ',') -notcontains 'windows') { continue }
    $prefix = Join-Path (Join-Path $env:LAPLACE_DEPS $f[0]) $f[1]
    if (-not (Test-Path $prefix)) { continue }
    # the tool's own programs only. Strawberry Perl also carries a compiler suite (c\bin: gcc, an old cmake, make):
    # that is never put on the PATH, where it would stand in for the machine's CMake and the contract's compiler.
    foreach ($d in @($prefix, (Join-Path $prefix 'bin'), (Join-Path $prefix 'perl\bin'))) { if (@(Get-ChildItem -LiteralPath $d -Filter *.exe -File -ErrorAction SilentlyContinue).Count) { $d } }
}
# after what is already there: a tool of the manifest never stands in for the machine's CMake, Ninja or Git
foreach ($d in $tools) { if (($env:PATH -split ';') -notcontains $d) { $env:PATH = "$env:PATH;$d" } }
foreach ($s in $said) { Write-Warning $s }

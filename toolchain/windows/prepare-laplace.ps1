#Requires -Version 7
[CmdletBinding()]
param([Parameter(Mandatory)][string]$LaplaceRoot)
$ErrorActionPreference = 'Stop'
$operations = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. "$operations/laplace.env.ps1"
$LaplaceRoot = (Resolve-Path -LiteralPath $LaplaceRoot).Path
if (-not $env:LAPLACE_UCD_ROOT) { $env:LAPLACE_UCD_ROOT = Join-Path $env:LAPLACE_UCD 'Public/UCD/latest' }
$manifest = if ($env:LAPLACE_DEPENDENCY_MANIFEST) { $env:LAPLACE_DEPENDENCY_MANIFEST } else { Join-Path $env:ProgramData 'Laplace/dependencies.tsv' }
[void](New-Item -ItemType Directory -Path (Split-Path $manifest) -Force)
Copy-Item -LiteralPath "$operations/dependencies.tsv" -Destination $manifest -Force
& pwsh -NoProfile -File "$operations/grammars.ps1" fetch -Directory (Join-Path $env:LAPLACE_EXTERNAL 'tree-sitter-grammars') -LaplaceRoot $LaplaceRoot
if ($LASTEXITCODE) { throw 'Grammar provisioning failed.' }
$unicode = Get-Content -LiteralPath "$operations/toolchain/unicode.lock.json" -Raw | ConvertFrom-Json
$ucdRoot = [IO.Path]::GetFullPath($env:LAPLACE_UCD_ROOT)
$cmake = Get-Content -LiteralPath (Join-Path $LaplaceRoot 'engine/CMakeLists.txt') -Raw
if ($cmake -notmatch ('set\(LAPLACE_UNICODE_VERSION\s+"' + [regex]::Escape($unicode.version) + '"')) {
    throw 'Unicode lock does not match the selected Laplace source.'
}
$verified = @()
foreach ($file in $unicode.files) {
    $path = [IO.Path]::GetFullPath((Join-Path $ucdRoot $file.path))
    if (-not $path.StartsWith($ucdRoot.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unicode file escaped its input root.' }
    if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) {
        [void](New-Item -ItemType Directory -Path (Split-Path $path) -Force)
        $temporary = "$path.download-$([guid]::NewGuid().ToString('N'))"
        try {
            Invoke-WebRequest -Uri "https://www.unicode.org/Public/$($unicode.version)/$($file.path)" -OutFile $temporary -TimeoutSec 60
            if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $file.sha256) { throw "Unicode checksum differs: $($file.path)" }
            Move-Item -LiteralPath $temporary -Destination $path -Force
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    }
    $verified += $file.path
}
$archive = Join-Path $ucdRoot 'ucd/UCD.zip'
$stamp = Join-Path $ucdRoot 'ucd/.laplace-archive-sha256'
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if (-not (Test-Path -LiteralPath $stamp) -or (Get-Content -LiteralPath $stamp -Raw).Trim() -ne $archiveHash -or
    -not (Test-Path (Join-Path $ucdRoot 'ucd/auxiliary/GraphemeBreakTest.txt')) -or
    -not (Test-Path (Join-Path $ucdRoot 'ucd/NormalizationTest.txt'))) {
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $ucdRoot 'ucd') -Force
    Set-Content -LiteralPath $stamp -Value $archiveHash
}
[ordered]@{unicode_version=$unicode.version; input_root=$ucdRoot; verified_files=$verified; source=$LaplaceRoot} | ConvertTo-Json

#Requires -Version 7
[CmdletBinding()]
param(
    [ValidateSet('fetch','status')][string]$Operation = 'status',
    [Parameter(Mandatory)][string]$Directory,
    [string]$LaplaceRoot,
    [string]$Manifest = "$PSScriptRoot/grammars.lock.tsv",
    [ValidateRange(1,16)][int]$Parallelism = 4
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($Directory)
$rows = @(Import-Csv -LiteralPath $Manifest -Delimiter "`t")
if ($LaplaceRoot) {
    $cmake = Get-Content -LiteralPath (Join-Path $LaplaceRoot 'engine/core/grammars/CMakeLists.txt') -Raw
    $required = @([regex]::Matches($cmake, '\$\{_TSG\}/([^/"\s]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if (-not $required.Count) { throw 'The selected Laplace source declares no external grammars.' }
    foreach ($name in $required) { if ($name -notin $rows.name) { throw "No locked grammar revision for $name" } }
    $rows = @($rows | Where-Object name -in $required)
}
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $rows) {
    $origin = [uri]$row.origin
    if ($row.name -notmatch '^[A-Za-z0-9_-]+$' -or $row.commit -notmatch '^[a-f0-9]{40}$' -or
        $origin.Scheme -ne 'https' -or $origin.UserInfo -or -not $names.Add($row.name)) { throw 'Invalid or duplicate locked grammar record.' }
}
if ($Operation -eq 'fetch') { [void](New-Item -ItemType Directory -Path $root -Force) }
$results = @($rows | ForEach-Object -ThrottleLimit $Parallelism -Parallel {
    $ErrorActionPreference = 'Stop'
    $row = $_; $path = [IO.Path]::Combine($using:root, $row.name); $lock = $null
    function Invoke-GrammarGit([string[]]$Arguments) {
        $result = & git @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git failed for $($row.name): $($result -join ' ')" }
        ($result -join "`n").Trim()
    }
    try {
        if ($using:Operation -eq 'fetch') {
            $lock = [IO.File]::Open([IO.Path]::Combine($using:root, ".$($row.name).lock"), 'OpenOrCreate', 'ReadWrite', 'None')
            if (-not (Test-Path -LiteralPath $path)) { [void](New-Item -ItemType Directory -Path $path) }
            if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
                if (@(Get-ChildItem -LiteralPath $path -Force).Count) { throw "Refusing to adopt nonempty directory: $path" }
                $null = Invoke-GrammarGit @('init','--quiet',$path)
                $null = Invoke-GrammarGit @('-C',$path,'remote','add','origin',$row.origin)
            }
            if ((Invoke-GrammarGit @('-C',$path,'remote','get-url','origin')) -ne $row.origin) { throw "Origin differs: $path" }
            if (Invoke-GrammarGit @('-C',$path,'status','--porcelain')) { throw "Uncommitted files in $path; no source changed." }
            $head = & git -C $path rev-parse --verify HEAD 2>$null
            if ($LASTEXITCODE -ne 0 -or $head -ne $row.commit) {
                $null = Invoke-GrammarGit @('-C',$path,'fetch','--quiet','--depth','1','origin',$row.commit)
                $null = Invoke-GrammarGit @('-C',$path,'checkout','--quiet','--detach',$row.commit)
            }
        }
        $head = Invoke-GrammarGit @('-C',$path,'rev-parse','HEAD')
        if ($head -ne $row.commit -or (Invoke-GrammarGit @('-C',$path,'status','--porcelain'))) { throw "Source differs from locked revision: $path" }
        [pscustomobject]@{name=$row.name; commit=$head; verified=$true}
    } catch { [pscustomobject]@{name=$row.name; verified=$false; error=$_.Exception.Message} }
    finally { if ($lock) { $lock.Dispose() } }
})
$failed = @($results | Where-Object { -not $_.verified })
[ordered]@{directory=$root; manifest_sha256=(Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant(); selected=$rows.Count; verified=$results.Count-$failed.Count; failures=$failed} | ConvertTo-Json -Depth 4
if ($failed.Count) { exit 1 }

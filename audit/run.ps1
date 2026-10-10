[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Output,
    [string[]]$LocalRoots = @(),
    [switch]$Refresh
)
$ErrorActionPreference='Stop'
$Output=[IO.Path]::GetFullPath($Output)
[void](New-Item -ItemType Directory -Force -Path $Output)
$catalog=& gh repo list $Owner --limit 1000 --json name,url,isArchived,isPrivate,defaultBranchRef,description
if($LASTEXITCODE -ne 0){throw 'GitHub repository discovery failed'}
$catalog | Set-Content -LiteralPath (Join-Path $Output 'catalog.json') -Encoding utf8
& "$PSScriptRoot/acquire-repositories.ps1" -Output $Output -Refresh:$Refresh
if($LASTEXITCODE -ne 0){throw 'Repository acquisition was incomplete; inspect acquisition.json'}
$scanArgs=@("$PSScriptRoot/configuration-index.mjs",'--output',$Output)
if($LocalRoots.Count){
    & node "$PSScriptRoot/discover-repositories.mjs" --roots ($LocalRoots -join ';') --output $Output
    if($LASTEXITCODE -ne 0){throw 'Local repository discovery failed'}
    $scanArgs+=@('--repository-list',(Join-Path $Output 'repository-discovery.json'))
}
& node @scanArgs
if($LASTEXITCODE -ne 0){throw 'Configuration scan failed or was incomplete'}
& node "$PSScriptRoot/review-configuration.mjs" --output $Output
if($LASTEXITCODE -ne 0){throw 'Glossary review enrichment failed'}
& node "$PSScriptRoot/index-search.mjs" --output $Output
if($LASTEXITCODE -ne 0){throw 'Search indexing failed'}
Write-Output "Audit written to $Output"
Write-Output "View: node `"$PSScriptRoot/serve-index.mjs`" --output `"$Output`""

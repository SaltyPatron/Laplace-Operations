#Requires -Version 7
param(
    [Parameter(Mandatory)][string[]]$Repositories,
    [string]$Configuration = "$PSScriptRoot/installation.json"
)
$ErrorActionPreference = 'Stop'
$values = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable
foreach ($key in 'LAPLACE_GCP_PROJECT','LAPLACE_CLOUD_INSTANCE','LAPLACE_CLOUD_ZONE','LAPLACE_GCP_WIF_PROVIDER','LAPLACE_GCP_SERVICE_ACCOUNT') {
    if (-not $values[$key]) { throw "Missing cloud declaration: $key" }
}
foreach ($repository in @($Repositories | ForEach-Object { $_ -split ',' })) {
    foreach ($item in $values.GetEnumerator()) {
        & gh variable set $item.Key --repo $repository --body $item.Value
        if ($LASTEXITCODE) { throw "Cloud declaration failed: $repository / $($item.Key)" }
    }
    Write-Output "$repository cloud declarations published"
}

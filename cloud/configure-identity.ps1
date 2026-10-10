#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Branch = 'main',
    [string]$Configuration = "$PSScriptRoot/installation.json",
    [string]$ControlHost,
    [string]$Gcloud = 'gcloud'
)
$ErrorActionPreference = 'Stop'
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Branch -notmatch '^[A-Za-z0-9_./-]+$') {
    throw 'Repository and branch must be explicit GitHub names.'
}
$values = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable
$provider = $values.LAPLACE_GCP_WIF_PROVIDER
if ($provider -notmatch '^(projects/[0-9]+/locations/global/workloadIdentityPools/[^/]+)/providers/[^/]+$') {
    throw 'The installation must declare a complete GCP workload identity provider.'
}
$pool = $Matches[1]
$oidc = & gh api "repos/$Repository/actions/oidc/customization/sub"
if ($LASTEXITCODE) { throw 'Cannot read the repository OIDC subject configuration.' }
$claims = $oidc | ConvertFrom-Json
if (-not $claims.use_default -or -not $claims.sub_claim_prefix) {
    throw 'Custom OIDC claims require a separately declared trust policy; refusing to guess the subject.'
}
$subject = "$($claims.sub_claim_prefix):ref:refs/heads/$Branch"
$member = "principal://iam.googleapis.com/$pool/subject/$subject"
$arguments = @('iam','service-accounts','add-iam-policy-binding', $values.LAPLACE_GCP_SERVICE_ACCOUNT,
    "--project=$($values.LAPLACE_GCP_PROJECT)", '--role=roles/iam.workloadIdentityUser', "--member=$member", '--quiet','--format=none')
if ($ControlHost) {
    # POSIX quote every argument, including caller-specified paths; never interpolate raw shell code.
    $quoted = @(@($Gcloud) + $arguments | ForEach-Object { "'" + ([string]$_).Replace("'", "'\''") + "'" })
    & ssh -o BatchMode=yes $ControlHost ($quoted -join ' ')
} else {
    & $Gcloud @arguments
}
if ($LASTEXITCODE) { throw 'GCP did not install the workload identity binding.' }
[ordered]@{ repository=$Repository; branch=$Branch; subject=$subject; provider=$provider;
    service_account=$values.LAPLACE_GCP_SERVICE_ACCOUNT; immutable_subject=$claims.use_immutable_subject } | ConvertTo-Json

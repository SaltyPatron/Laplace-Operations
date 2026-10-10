[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output, [switch]$Refresh)
$ErrorActionPreference = 'Stop'
$catalog = Get-Content -LiteralPath (Join-Path $Output 'catalog.json') -Raw | ConvertFrom-Json
$cache = Join-Path $Output 'repositories'
$treeDirectory = Join-Path $Output 'trees'
[void](New-Item -ItemType Directory -Force -Path $treeDirectory)
$prior = @{}
if (Test-Path -LiteralPath (Join-Path $Output 'acquisition.json')) {
    foreach ($entry in (Get-Content -LiteralPath (Join-Path $Output 'acquisition.json') -Raw | ConvertFrom-Json)) { $prior[$entry.name] = $entry }
}
[void](New-Item -ItemType Directory -Force -Path $cache)
$results = $catalog | ForEach-Object -Parallel {
    $repo = $_
    $known = ($using:prior)[$repo.name]
    if ($known -and $known.exit_code -eq 0 -and -not $using:Refresh) { $result=$known } else {
    $destination = Join-Path $using:cache ($repo.name + '.git')
    $started = [DateTime]::UtcNow.ToString('o')
    if (Test-Path -LiteralPath $destination) {
        $log = & git -C $destination fetch --depth=1 origin $repo.defaultBranchRef.name 2>&1
        $code = $LASTEXITCODE
        $revision = if ($code -eq 0) { & git -C $destination rev-parse FETCH_HEAD }
    } else {
        $log = & git clone --bare --depth=1 --filter=blob:limit=1m --single-branch --branch $repo.defaultBranchRef.name ($repo.url + '.git') $destination 2>&1
        $code = $LASTEXITCODE
        $revision = if ($code -eq 0) { & git -C $destination rev-parse HEAD }
    }
    $empty=$false
    if($code -ne 0) {
        $owner=($repo.url.TrimEnd('/') -split '/')[-2]
        $answer=& gh api graphql -f 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){isEmpty}}' -F "owner=$owner" -F "name=$($repo.name)" --jq .data.repository.isEmpty 2>$null
        if($LASTEXITCODE -eq 0 -and $answer -eq 'true') { $empty=$true; $code=0 }
    }
    $result=[pscustomobject]@{
        name=$repo.name; url=$repo.url; path=$destination; branch=$repo.defaultBranchRef.name
        revision=$revision; exit_code=$code; fetched_utc=$started
        # Clone output is not indexed: credential helpers must never become report contents.
        error=if($code -eq 0){$null}else{'Git acquisition failed; inspect repository access locally.'}
        empty=$empty
    }
    }
    if($result.exit_code -eq 0 -and -not $result.empty) {
        $treePath=Join-Path $using:treeDirectory ($repo.name+'-'+$result.revision+'.json')
        if(-not(Test-Path -LiteralPath $treePath)) {
            $owner=($repo.url.TrimEnd('/') -split '/')[-2]
            $tree=& gh api "repos/$owner/$($repo.name)/git/trees/$($result.revision)?recursive=1"
            if($LASTEXITCODE -ne 0) { $result.exit_code=1; $result.error='Tree metadata acquisition failed.' }
            else { $tree | Set-Content -LiteralPath $treePath -Encoding utf8 }
        }
    }
    $result
} -ThrottleLimit 3
$results | Sort-Object name | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Output 'acquisition.json') -Encoding utf8
$results | Sort-Object name | Select-Object name,revision,exit_code | Format-Table -AutoSize
if (@($results | Where-Object exit_code -ne 0).Count) { exit 1 }

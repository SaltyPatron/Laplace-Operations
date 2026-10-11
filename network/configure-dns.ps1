#Requires -Version 7
[CmdletBinding()]
param([string]$Configuration="$PSScriptRoot/environments.json",[switch]$Apply)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json
function Invoke-DnsCli([string[]]$Arguments) {
    $result=& cf @Arguments -z $config.zone -q
    if ($LASTEXITCODE) { throw 'Cloudflare DNS operation failed.' }
    $result | ConvertFrom-Json
}
$records=@(Invoke-DnsCli @('dns','records','list'))
$result=foreach($environment in $config.environments | Where-Object dns_target) {
    $name=([Uri]$environment.browser_origin).DnsSafeHost
    if (-not $name.EndsWith('.'+$config.zone) -or -not $environment.dns_target.EndsWith('.'+$config.zone)) {
        throw 'Private application names and their targets must belong to the declared zone.'
    }
    $found=@($records | Where-Object name -eq $name)
    if ($found.Count -gt 1 -or ($found.Count -eq 1 -and
        ($found[0].type -ne 'CNAME' -or $found[0].content -ne $environment.dns_target -or $found[0].proxied))) {
        throw "DNS name $name conflicts with its declaration; no existing record was replaced."
    }
    if (-not $found.Count -and $Apply) {
        $body=@{type='CNAME';name=$name;content=$environment.dns_target;ttl=120;proxied=$false} | ConvertTo-Json -Compress
        $null=Invoke-DnsCli @('dns','records','create','--body',$body)
        $found=@(Invoke-DnsCli @('dns','records','list') | Where-Object name -eq $name)
    }
    $verified=$found.Count -eq 1 -and $found[0].type -eq 'CNAME' -and $found[0].content -eq $environment.dns_target -and -not $found[0].proxied
    [ordered]@{name=$name;target=$environment.dns_target;proxied=$false;verified=$verified}
    if ($Apply -and -not $verified) { throw "Cloudflare did not retain $name." }
}
$result | ConvertTo-Json -Depth 4

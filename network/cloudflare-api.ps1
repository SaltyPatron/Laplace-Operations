#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9.-]+$')][string]$Zone,
    [Parameter(Mandatory)][string[]]$ApiHosts,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
foreach ($hostName in $ApiHosts) {
    if ($hostName -notmatch '^[A-Za-z0-9.-]+$' -or -not $hostName.EndsWith(".$Zone", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Every API hostname must belong to the declared zone.'
    }
}
function Invoke-Cf([string[]]$Arguments) {
    $result = & cf @Arguments -z $Zone -q
    if ($LASTEXITCODE -ne 0) { throw 'Cloudflare operation failed.' }
    $result | ConvertFrom-Json -Depth 50
}
$hostsExpression = (@($ApiHosts | Sort-Object -Unique) | ForEach-Object { '"' + $_.ToLowerInvariant() + '"' }) -join ' '
$rule = @{
    ref = 'laplace_programmatic_api_clients'
    description = 'Allow programmatic user agents on authenticated Laplace API and MCP hosts'
    expression = '(http.host in {' + $hostsExpression + '})'
    action = 'set_config'
    action_parameters = @{ bic = $false }
    enabled = $true
}
$rulesets = @(Invoke-Cf @('rulesets','list'))
$entry = @($rulesets | Where-Object { $_.kind -eq 'zone' -and $_.phase -eq 'http_config_settings' })
if ($entry.Count -gt 1) { throw 'Multiple configuration entry points returned; no rule changed.' }
if (-not $entry.Count) {
    if (-not $Apply) { throw 'API configuration rule is absent. Run with -Apply to install the declared rule.' }
    $body = @{ name = 'Application configuration'; kind = 'zone'; phase = 'http_config_settings'; rules = @($rule) } | ConvertTo-Json -Depth 8 -Compress
    $entry = @(Invoke-Cf @('rulesets','create','--body',$body))
}
$current = Invoke-Cf @('rulesets','get',$entry[0].id)
$found = @($current.rules | Where-Object ref -eq $rule.ref)
if ($found.Count -gt 1) { throw 'Duplicate managed API rules; no rule changed.' }
if ($found.Count -eq 0) {
    if (-not $Apply) { throw 'API configuration rule is absent.' }
    $null = Invoke-Cf @('rulesets','rules','create',$current.id,'--body',($rule | ConvertTo-Json -Depth 8 -Compress))
} elseif ($found[0].expression -ne $rule.expression -or $found[0].action_parameters.bic -ne $false -or -not $found[0].enabled) {
    if (-not $Apply) { throw 'API configuration rule differs from its declaration.' }
    $null = Invoke-Cf @('rulesets','rules','update',$current.id,$found[0].id,'--body',($rule | ConvertTo-Json -Depth 8 -Compress))
}
$verified = Invoke-Cf @('rulesets','get',$current.id)
$actual = @($verified.rules | Where-Object ref -eq $rule.ref)
if ($actual.Count -ne 1 -or $actual[0].expression -ne $rule.expression -or $actual[0].action_parameters.bic -ne $false -or -not $actual[0].enabled) {
    throw 'Cloudflare did not retain the declared API configuration.'
}
[ordered]@{zone=$Zone; hosts=$ApiHosts; ruleset=$verified.id; rule=$actual[0].id; browser_integrity_check=$false} | ConvertTo-Json

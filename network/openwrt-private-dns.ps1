#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9@._-]+$')][string]$Router,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9@._-]+$')][string]$TailnetHost,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9,-]+$')][string[]]$Nodes,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9.-]+$')][string]$LocalDomain,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../secrets/process.ps1"
$Nodes = @($Nodes | ForEach-Object { $_ -split ',' })
if ($Nodes -contains '') { throw 'Node names must not be empty' }
$status = Invoke-Program ssh @('-o','BatchMode=yes',$TailnetHost,'tailscale status --json') | ConvertFrom-Json
$peers = @($status.Self) + @($status.Peer.PSObject.Properties.Value)
$records = foreach ($node in $Nodes) {
    $nodeMatches = @($peers | Where-Object { ($_.DNSName -split '\.')[0] -eq $node })
    if ($nodeMatches.Count -ne 1) { throw "Expected one Tailscale node named $node" }
    $addresses = @($nodeMatches[0].TailscaleIPs | Where-Object { [Net.IPAddress]::Parse($_).AddressFamily -eq 'InterNetwork' })
    if ($addresses.Count -ne 1 -or $addresses[0] -notmatch '^100\.[0-9.]+$') { throw "No unambiguous Tailscale IPv4 address for $node" }
    [ordered]@{name="$node.$LocalDomain"; address=$addresses[0]; node_id=$nodeMatches[0].ID; magic_dns=$nodeMatches[0].DNSName; section=('laplace_' + $node.Replace('-','_'))}
}
$body = [Collections.Generic.List[string]]::new()
$body.Add(@'
set -eu
# Do not commit somebody else's staged UCI changes with these records.
[ -z "$(uci changes dhcp)" ] || { echo 'Uncommitted DHCP changes exist' >&2; exit 1; }
changed=0
'@)
foreach ($record in $records) {
    $section = $record.section; $name = $record.name; $address = $record.address
    $body.Add("if [ `"`$(uci -q get dhcp.$section.name || true)`" != '$name' ] || [ `"`$(uci -q get dhcp.$section.ip || true)`" != '$address' ]; then changed=1; fi")
}
if ($Apply) {
    $body.Add(@'
if [ "$changed" = 1 ]; then
  backup="/etc/config/dhcp.laplace-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p /etc/config/dhcp "$backup"
  rollback() {
    result=$?
    if [ "$result" != 0 ]; then
      uci revert dhcp
      cp -p "$backup" /etc/config/dhcp
      /etc/init.d/dnsmasq reload
    fi
    exit "$result"
  }
  trap rollback EXIT
'@)
    foreach ($record in $records) {
        $body.Add("uci set dhcp.$($record.section)=domain")
        $body.Add("uci set dhcp.$($record.section).name='$($record.name)'")
        $body.Add("uci set dhcp.$($record.section).ip='$($record.address)'")
    }
    $body.Add("uci commit dhcp`n/etc/init.d/dnsmasq reload`nfi")
} else {
    $body.Add('[ "$changed" = 0 ] || { echo "Private DNS differs; apply the declared node records" >&2; exit 1; }')
}
foreach ($record in $records) {
    $body.Add("attempt=0; until nslookup '$($record.name)' 127.0.0.1 | grep -F '$($record.address)' >/dev/null; do attempt=`$((attempt + 1)); [ `"`$attempt`" -lt 5 ] || exit 1; sleep 1; done")
}
$body.Add('trap - EXIT; echo verified')
$result = Invoke-Program ssh @('-o','BatchMode=yes',$Router,'sh -s') (($body -join "`n").Replace("`r",'') + "`n")
if ($result.Trim() -ne 'verified') { throw 'Router did not verify its private DNS records' }
foreach ($record in $records) {
    $resolved = Invoke-Program ssh @('-o','BatchMode=yes',$TailnetHost,"getent ahostsv4 '$($record.name)'")
    if (($resolved -split '\s+') -notcontains $record.address) { throw "The client resolver does not return the selected address for $($record.name)" }
}
[ordered]@{router=$Router; tailnet_host=$TailnetHost; applied=[bool]$Apply; records=@($records); verified=$true; client_resolution='verified'} | ConvertTo-Json -Depth 5

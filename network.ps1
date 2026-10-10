#Requires -Version 7
<# Resolve explicit LAN names locally, and tailnet names through MagicDNS.
   setup.ps1 network applies this; network.ps1 -Check checks the current state.
   Existing search domains are preserved. No exit node, subnet route, DHCP or public DNS is changed. #>
param([switch]$Check, [string]$ResultPath = "$env:LOCALAPPDATA\Laplace\network-last.json")
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ Time=(Get-Date -Format o); Machine=$env:COMPUTERNAME; Check=[bool]$Check; Success=$false }
try {
    $state = tailscale status --json | ConvertFrom-Json
    if ($LASTEXITCODE -or $state.BackendState -ne 'Running') { throw 'Tailscale is not connected.' }
    $prefs = tailscale debug prefs | ConvertFrom-Json
    if ($LASTEXITCODE) { throw 'Cannot read Tailscale DNS settings.' }
    $tailDomain = $state.CurrentTailnet.MagicDNSSuffix
    if (-not $tailDomain) { throw 'The tailnet has no MagicDNS suffix.' }
    $before = @((Get-DnsClientGlobalSetting).SuffixSearchList)
    $up = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    $lanDomains = @(Get-DnsClient | Where-Object { $_.InterfaceIndex -in $up -and $_.InterfaceAlias -ne 'Tailscale' -and $_.ConnectionSpecificSuffix } | Select-Object -ExpandProperty ConnectionSpecificSuffix)
    $desired = @(@($before + $lanDomains | Where-Object { $_ -and $_ -ne $tailDomain }) + $tailDomain | Select-Object -Unique)
    $result.Before = @{AcceptDns=[bool]$prefs.CorpDNS;SearchDomains=$before}
    $result.SearchDomains = $desired
    $drift = -not $prefs.CorpDNS -or ($before -join ',') -ne ($desired -join ',')
    if ($drift -and $Check) { throw "DNS configuration differs: use network.ps1 from an elevated PowerShell; expected suffix order $($desired -join ', ')." }
    if ($drift) {
        if (-not [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Changing DNS search order requires an elevated PowerShell.' }
        try {
            Set-DnsClientGlobalSetting -SuffixSearchList $desired
            tailscale set --accept-dns=true
            if ($LASTEXITCODE) { throw 'Tailscale refused the DNS change.' }
            Clear-DnsClientCache
        } catch {
            Set-DnsClientGlobalSetting -SuffixSearchList $before
            & tailscale set "--accept-dns=$(([bool]$prefs.CorpDNS).ToString().ToLowerInvariant())"
            throw
        }
    }
    $lookups = @()
    $peers = @($state.Self) + @($state.Peer.PSObject.Properties.Value)
    foreach ($peer in $peers) {
        $name = $peer.HostName
        $ips = @([Net.Dns]::GetHostAddresses($name) | ForEach-Object IPAddressToString)
        $fqdn = $peer.DNSName.TrimEnd('.')
        $tailIps = @([Net.Dns]::GetHostAddresses($fqdn) | ForEach-Object IPAddressToString)
        if (-not @($tailIps | Where-Object { $_ -in $peer.TailscaleIPs }).Count) { throw "Unexpected tailnet DNS answer for $fqdn" }
        # Tailscale owns bare peer names in the Windows hosts file. LAN-bound services use the explicit LAN name.
        $lanNames = @()
        foreach ($suffix in $lanDomains) {
            try { $localIps = @([Net.Dns]::GetHostAddresses("$name.$suffix") | ForEach-Object IPAddressToString) } catch { continue }
            $lanNames += [pscustomobject]@{Name="$name.$suffix";Addresses=$localIps}
        }
        $lookups += [pscustomobject]@{Name=$name;Addresses=$ips;Lan=$lanNames;TailnetAddresses=$tailIps;Online=$peer.Online}
    }
    $result.Lookups = $lookups
    $result.InternetDns = @([Net.Dns]::GetHostAddresses('github.com') | ForEach-Object IPAddressToString)
    $result.Success = $true
    $lookups | Format-Table Name,@{n='Addresses';e={$_.Addresses -join ', '}},Online -AutoSize
    "DNS verified: explicit LAN and tailnet names; internet DNS works. Bare peer names belong to Tailscale. Offline peers were not started."
} catch {
    $result.Error = $_.Exception.Message
    Write-Output "FAILED: $($result.Error)"
} finally {
    New-Item -ItemType Directory -Force (Split-Path $ResultPath) | Out-Null
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath
}
if (-not $result.Success) { exit 1 }

# Shared inventory for setup, deployment and laplace-ops clients. No process is
# stopped here: stdio connections belong to their calling applications.
function Get-DesktopClientDeclaration([string]$Path) {
    if (-not $Path) { $Path=Join-Path $PSScriptRoot ($env:COMPUTERNAME.ToLowerInvariant()+'-modular-client.json') }
    $declaration=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($declaration.schema -ne 'laplace.modular-installation/v1' -or $declaration.host -ine $env:COMPUTERNAME) {
        throw 'The modular client declaration must select this Windows host.'
    }
    $declaration
}

function Get-DesktopServiceReaders {
    return @()
}

function Get-DesktopClientState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Declaration, [object[]]$Processes, [object[]]$ServiceReaders)
    $installed=Get-Content -LiteralPath $Declaration.installed_config -Raw | ConvertFrom-Json
    $releases=[IO.Path]::GetFullPath((Join-Path $Declaration.prefix 'releases')).TrimEnd('\','/')
    $selected=[IO.Path]::GetFullPath($installed.release).TrimEnd('\','/')
    if ($installed.schema -ne $Declaration.schema -or $installed.host -ine $Declaration.host -or
        [IO.Path]::GetFullPath($installed.prefix) -ine [IO.Path]::GetFullPath($Declaration.prefix) -or
        [IO.Path]::GetDirectoryName($selected) -ine $releases) {
        throw 'Installed modular selection differs from the declared host or release directory.'
    }
    $package=Get-Content -LiteralPath (Join-Path $selected 'package.json') -Raw | ConvertFrom-Json
    if ($package.schema -ne 'laplace.modular-package/v1') { throw 'Selected release is not a modular package.' }
    if (-not $PSBoundParameters.ContainsKey('Processes')) { $Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop) }
    if (-not $PSBoundParameters.ContainsKey('ServiceReaders')) { $ServiceReaders=@(Get-DesktopServiceReaders) }
    $byId=@{}; foreach ($process in $Processes) { $byId[[int]$process.ProcessId]=$process }
    $running=@(); $unobservable=@();$services=@()
    foreach ($process in $Processes) {
        if (-not $process.ExecutablePath) {
            if ($process.Name -in @('lpm.exe','laplace.exe')) {
                $parent=$byId[[int]$process.ParentProcessId]
                $evidence=@($ServiceReaders|Where-Object {
                    $_.pid -eq [int]$process.ProcessId -and $_.parent_pid -eq [int]$process.ParentProcessId -and
                    $_.source -ceq 'verified-iis-health' -and $_.executable_sha256 -match '^[a-f0-9]{64}$' -and
                    $parent.Name -ieq 'w3wp.exe' -and $parent.CreationDate -le $process.CreationDate -and
                    $process.CreationDate -and [math]::Abs((([datetimeoffset]$_.started_utc).UtcDateTime-([datetime]$process.CreationDate).ToUniversalTime()).TotalMilliseconds) -lt 10 -and
                    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($_.release).TrimEnd('\','/')) -ieq $releases
                })
                if($evidence.Count -eq 1){$services+=$evidence[0]}else{$unobservable += [int]$process.ProcessId}
            }
            continue
        }
        $executable=[IO.Path]::GetFullPath($process.ExecutablePath)
        if (-not $executable.StartsWith($releases+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative=$executable.Substring($releases.Length+1).Split([IO.Path]::DirectorySeparatorChar)
        if ($relative.Count -lt 2) { continue }
        $release=Join-Path $releases $relative[0]
        $ancestry=@(); $seen=@{}; $child=$process
        for ($i=0; $i -lt 12; $i++) {
            $parent=$byId[[int]$child.ParentProcessId]
            # Do not attribute a recycled parent PID to an older child.
            if (-not $parent -or $seen.ContainsKey([int]$parent.ProcessId) -or
                -not $parent.CreationDate -or -not $child.CreationDate -or
                $parent.CreationDate -gt $child.CreationDate) { break }
            $seen[[int]$parent.ProcessId]=$true
            $ancestry += [ordered]@{pid=[int]$parent.ProcessId;name=$parent.Name}
            $child=$parent
        }
        $mode=if ($process.Name -ieq 'lpm.exe' -and $process.CommandLine -match '\smcp(?:\s|$)') {'mcp-stdio'} else {'native-process'}
        $running += [ordered]@{pid=[int]$process.ProcessId;started_utc=([datetime]$process.CreationDate).ToUniversalTime().ToString('o');
            executable=$executable;release=$release;selected=($release -ieq $selected);mode=$mode;parents=$ancestry}
    }
    $stale=@($running | Where-Object { -not $_.selected })
    $status=if ($unobservable.Count) {'unverifiable'} elseif ($stale.Count) {'reconnect_required'} else {'current'}
    $retention=foreach ($directory in Get-ChildItem -LiteralPath $releases -Directory) {
        $holders=@(@($running)+@($services) | Where-Object { $_.release -ieq $directory.FullName } | ForEach-Object pid)
        $reasons=@()
        if ($directory.FullName -ieq $selected) { $reasons += 'installed_selection' }
        if ($holders.Count) { $reasons += 'running_process' }
        if ($unobservable.Count) { $reasons += 'process_visibility_incomplete' }
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { $reasons += 'reparse_point' }
        [ordered]@{release=$directory.FullName;pids=$holders;protected=($reasons.Count -gt 0);reasons=$reasons;
            retirement=if ($reasons.Count) {'blocked'} else {'requires_reference_audit'}}
    }
    [ordered]@{schema='laplace.desktop-clients/v1';checked_utc=[DateTime]::UtcNow.ToString('o');host=$Declaration.host;
        status=$status;selected_release=$selected;revisions=$package.revisions;processes=$running;service_readers=$services;
        stale_count=$stale.Count;unobservable_pids=$unobservable;releases=@($retention);
        reconnect_policy='Reconnect each reported MCP client to launch the selected release; active stdio sessions remain pinned. Let older native commands finish. Run laplace-ops clients verify afterward. No client application is terminated.'}
}

function Write-DesktopClientState($State) {
    Write-Host "Modular installed release: $($State.selected_release)"
    foreach ($process in $State.processes) {
        $owner=($process.parents | ForEach-Object { "$($_.name)($($_.pid))" }) -join ' <- '
        Write-Host "  PID $($process.pid) $($process.mode): $($process.release) <- $owner"
    }
    if ($State.status -ne 'current') {
        Write-Warning "Modular clients: $($State.status); $($State.stale_count) older processes, $($State.unobservable_pids.Count) unobservable. $($State.reconnect_policy)"
    } else { Write-Host 'Modular clients: current. This inventory does not establish ingestion completion.' }
}

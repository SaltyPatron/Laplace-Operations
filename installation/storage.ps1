# Desktop artifact retention. Sources, databases, corpora and live build profiles
# are not garbage-collection targets. Publication and component-store locks are
# shared with their existing owners; deletion stays in this PowerShell process.
function Read-StorageJson([string]$Path) {
    if (-not $Path) { return $null }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    return $null
}

function Get-StorageAncestorIds {
    $parents=[Collections.Generic.HashSet[int]]::new()
    $current=$PID
    while ($current -and $parents.Add([int]$current)) {
        $current=(Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction Stop).ParentProcessId
    }
    return ,$parents
}

function Get-StorageBuildReferences([string]$BuildRoot,[string]$SourceRoot=$env:LAPLACE_SRC) {
    $references=@((Join-Path $BuildRoot 'Laplace'))
    foreach($name in 'LAPLACE_BUILD_ROOT','LAPLACE_ENGINE_BUILD','LAPLACE_ENGINE_BUILD_ASAN') {
        $value=[Environment]::GetEnvironmentVariable($name)
        if($value){$references+=$value}
    }
    foreach($repository in Get-ChildItem -LiteralPath $SourceRoot -Directory) {
        if(-not (Test-Path -LiteralPath (Join-Path $repository.FullName '.git'))){continue}
        $worktrees=@(& git -C $repository.FullName worktree list --porcelain)
        if($LASTEXITCODE){throw "Cannot audit build ownership for $($repository.FullName)"}
        foreach($line in $worktrees) {
            if($line -notmatch '^worktree (.+)$'){continue}
            $checkout=[IO.Path]::GetFullPath($Matches[1]).TrimEnd('\').ToLowerInvariant()
            if($checkout -eq [IO.Path]::GetFullPath((Join-Path $SourceRoot 'Laplace')).ToLowerInvariant()){continue}
            $identity=[IO.Path]::GetFileName($checkout)+'-'+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($checkout))).Substring(0,12).ToLowerInvariant()
            $references+=Join-Path $BuildRoot ('worktrees/'+$identity)
        }
    }
    return $references
}

function Get-StorageScratch([string]$Root,[string]$Pattern,[string]$Kind,[string[]]$References,[object[]]$Processes) {
    if(-not (Test-Path -LiteralPath $Root -PathType Container)){return @()}
    foreach($directory in Get-ChildItem -LiteralPath $Root -Directory -Force) {
        if($directory.Name -notmatch $Pattern){continue}
        $reasons=@()
        if(Test-StorageReference $directory.FullName $References $Processes){$reasons+='live_reference'}
        if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){$reasons+='reparse_point'}
        if($Kind -eq 'abandoned_build' -and @(Get-ChildItem -LiteralPath $directory.FullName -Filter .git -Recurse -Force).Count){$reasons+='source_checkout'}
        [pscustomobject]@{path=$directory.FullName;root=[IO.Path]::GetFullPath($Root);kind=$Kind;marker=$null;
            revision=$null;modified_utc=$directory.LastWriteTimeUtc.ToString('o');reasons=$reasons;retire=($reasons.Count -eq 0)}
    }
}

function Enter-DesktopStorageOperation([string]$WorkRoot=$env:LAPLACE_WORK,[switch]$IfIdle) {
    $previous=$env:LAPLACE_STORAGE_OWNER_PID
    $previousRoot=$env:LAPLACE_STORAGE_WORK_ROOT
    $fullRoot=[IO.Path]::GetFullPath($WorkRoot)
    if ($previous -match '^\d+$' -and (-not $previousRoot -or $previousRoot -ieq $fullRoot) -and (Get-StorageAncestorIds).Contains([int]$previous)) { return $null }
    $directory=Join-Path $WorkRoot 'operations'
    $null=New-Item -ItemType Directory -Path $directory -Force
    try { $lock=[IO.File]::Open((Join-Path $directory '.storage-operation.lock'),'OpenOrCreate','ReadWrite','None') }
    catch [IO.IOException] {
        if($IfIdle){Write-Warning 'History cleanup deferred while another Laplace operation owns storage.';return $false}
        throw 'Another Laplace build/install/publication owns storage. Run laplace-ops clean after it finishes; no rebuild is needed.'
    }
    $env:LAPLACE_STORAGE_OWNER_PID=[string]$PID
    $env:LAPLACE_STORAGE_WORK_ROOT=$fullRoot
    return @{lock=$lock;previous=$previous;previous_root=$previousRoot}
}

function Close-DesktopStorageOperation($Operation) {
    if ($Operation) {
        $env:LAPLACE_STORAGE_OWNER_PID=$Operation.previous
        $env:LAPLACE_STORAGE_WORK_ROOT=$Operation.previous_root
        $Operation.lock.Dispose()
    }
}

function Exit-DesktopStorageOperation {
    param($Operation,[string]$WorkRoot=$env:LAPLACE_WORK,[string]$BuildRoot=$env:LAPLACE_BUILD,$Modular,$Iis,
          [string[]]$DatabaseReferences,[string[]]$BuildReferences,[object[]]$Processes,[switch]$PassThru)
    if (-not $Operation) { return }
    try {
        . "$PSScriptRoot/desktop-clients.ps1"
        if(-not $Modular){$Modular=Get-DesktopClientDeclaration}
        if(-not $Iis){$Iis=Read-StorageJson $env:LAPLACE_IIS_INSTALLATION}
        # First-time setup can precede either installation. Its own private
        # scratch still belongs to its creator's finally block.
        if (-not $iis -or -not (Test-Path -LiteralPath $modular.installed_config) -or
            -not (Test-Path -LiteralPath (Join-Path $iis.directory 'web/active.json'))) { return }
        $arguments=@{WorkRoot=$WorkRoot;BuildRoot=$BuildRoot;Modular=$Modular;Iis=$Iis}
        foreach($name in 'DatabaseReferences','BuildReferences','Processes'){if($PSBoundParameters.ContainsKey($name)){$arguments[$name]=$PSBoundParameters[$name]}}
        $result=Invoke-DesktopStorageCleanup @arguments
        Write-Host "Cleanup: $($result.removed.Count) unused outputs removed. Receipt: $($result.receipt)"
        if($PassThru){return $result}
    } finally { Close-DesktopStorageOperation $Operation }
}

function Get-StorageDatabaseReferences([string]$Configuration="$PSScriptRoot/hart-desktop-operator.json") {
    $config = Read-StorageJson $Configuration
    $target = @($config.targets | Where-Object authentication -EQ sspi)
    if ($target.Count -ne 1 -or $target[0].host -ine $env:COMPUTERNAME) { throw 'Storage retirement requires the declared local database host.' }
    $target = $target[0]
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $target.prefix 'bin/psql.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @($start.Environment.Keys | Where-Object { $_ -like 'PG*' })) { $null=$start.Environment.Remove($name) }
    $start.Environment['PGSSLMODE']='verify-full'
    $start.Environment['PGSSLROOTCERT']=Join-Path $config.state 'hart-desktop-postgresql.crt'
    $start.Environment['PGREQUIREAUTH']='sspi'
    $start.Environment['PGCONNECT_TIMEOUT']='10'
    $start.Environment['PGPASSFILE']=Join-Path $config.state 'unused-no-password-file'
    $sql=@'
SELECT DISTINCT path FROM (
 SELECT pg_catalog.substr(setting,pg_catalog.strpos(setting,'=')+1) AS path
 FROM pg_catalog.pg_db_role_setting r CROSS JOIN LATERAL pg_catalog.unnest(r.setconfig) setting
 WHERE pg_catalog.split_part(setting,'=',1) IN ('laplace.tier0','laplace.flags','laplace.highway','laplace.chess')
 UNION ALL
 SELECT setting FROM pg_catalog.pg_file_settings
 WHERE name IN ('laplace.tier0','laplace.flags','laplace.highway','laplace.chess') AND error IS NULL
) config_paths WHERE path <> '';
'@
    foreach ($argument in @('-X','-w','-h',[string]$target.host,'-p',[string]$target.port,'-U',[string]$config.role,
                             '-d','postgres','-Atq','-v','ON_ERROR_STOP=1','-c',$sql)) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($start)
    try {
        $output=$process.StandardOutput.ReadToEndAsync()
        $errorOutput=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill($true);throw 'Database reference audit timed out; storage was not changed.' }
        if ($process.ExitCode) { throw ('Database reference audit failed: '+$errorOutput.GetAwaiter().GetResult()) }
        return @($output.GetAwaiter().GetResult().Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } finally { $process.Dispose() }
}

function Get-StorageProcesses {
    $result = @()
    foreach ($process in Get-CimInstance Win32_Process -ErrorAction Stop) {
        $modules = @()
        $moduleError = $false
        if ($process.Name -in @('w3wp.exe','dotnet.exe')) {
            try { $modules = @((Get-Process -Id $process.ProcessId -ErrorAction Stop).Modules | ForEach-Object FileName) }
            catch { $moduleError = $true }
        }
        $result += [pscustomobject]@{pid=$process.ProcessId;parent_pid=$process.ParentProcessId;name=$process.Name;executable=$process.ExecutablePath;
            command=$process.CommandLine;modules=$modules;module_error=$moduleError}
    }
    return $result
}

function Test-StorageReference([string]$Path, [string[]]$References, [object[]]$Processes) {
    $prefix = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    foreach ($reference in $References) {
        if (-not $reference) { continue }
        $full = [IO.Path]::GetFullPath($reference).TrimEnd('\','/')
        if ($full -ieq $prefix -or $full.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($process in $Processes) {
        foreach ($reference in @($process.executable)+@($process.modules)) {
            if ($reference -and ($reference -ieq $prefix -or $reference.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase))) { return $true }
        }
        $command = [string]$process.command
        if ($command.IndexOf($prefix,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $command.IndexOf($prefix.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Test-StorageLeaseOwner($Lease,[object[]]$Processes) {
    $owners=@(@($Lease.owner_pid,$Lease.child_pid)|Where-Object {$_ -gt 0}|Select-Object -Unique)
    do {
        $children=@($Processes|Where-Object {$_.pid -gt 0 -and $_.parent_pid -in $owners -and $_.pid -notin $owners}|ForEach-Object pid)
        $owners+=$children
    } while($children.Count)
    return @($Processes|Where-Object {$_.pid -in $owners}).Count -gt 0
}

function Get-StorageReceiptReferences($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [Collections.IDictionary]) { $members=@($Value.Keys | ForEach-Object { @{Name=$_;Value=$Value[$_]} }) }
    elseif ($Value -is [Collections.IEnumerable]) { foreach($item in $Value){Get-StorageReceiptReferences $item};return }
    else { $members=@($Value.PSObject.Properties) }
    foreach($member in $members) {
        if ($member.Name -in @('receipt','run_directory') -and $member.Value -is [string] -and
            [IO.Path]::IsPathFullyQualified($member.Value)) { $member.Value }
        else { Get-StorageReceiptReferences $member.Value }
    }
}

function Get-StorageOperationHistory {
    param([string]$Root,[object[]]$Processes,[string[]]$References,
          [ValidateRange(1,20)][int]$Successes=3,[ValidateRange(1,20)][int]$Failures=1)
    if(-not (Test-Path -LiteralPath $Root -PathType Container)){return @()}
    $entries=@();$records=@{}
    foreach($item in Get-ChildItem -LiteralPath $Root -Force) {
        if($item.PSIsContainer -and $item.Name -match '^(desktop-deploy|iis-database|modular-database|test|components)-\d{8}T\d{6,13}Z$') {
            $family=$Matches[1];$marker=if($family -eq 'components'){'components.json'}else{'receipt.json'}
            $receipt=Join-Path $item.FullName $marker
        } elseif($item.PSIsContainer -and $item.Name -match '^(desktop-run|desktop-verification)-\d{8}-\d{6}(?:-[a-f0-9]{8})?$') {
            $family=$Matches[1];$marker='receipt.json';$receipt=Join-Path $item.FullName $marker
        } elseif(-not $item.PSIsContainer -and $item.Name -match '^storage-\d{8}T\d{6,13}Z\.json$') {
            $family='storage';$marker=$null;$receipt=$item.FullName
        } elseif(-not $item.PSIsContainer -and $item.Name -match '^development-\d{8}-\d{6}\.json$') {
            $family='development';$marker=$null;$receipt=$item.FullName
        } else {continue}
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ((Test-Path -LiteralPath $receipt) -and ((Get-Item -LiteralPath $receipt).Attributes -band [IO.FileAttributes]::ReparsePoint))){continue}
        # Only the existing owners' completed receipts establish ownership.
        # Missing, malformed and unfinished output is not adopted by its name.
        try {$record=Read-StorageJson $receipt}catch{continue}
        if(-not $record){continue}
        $group=$null;$finished=$record.finished_utc;$status=$record.status
        switch($family) {
            'desktop-deploy' {
                if(-not $record.operation -or -not $record.target){continue}
                $group='deploy|'+$record.target
            }
            {$_ -in @('iis-database','modular-database')} {
                if(-not $record.host -or -not $record.database -or -not $record.operation -or $record.completed -isnot [bool]){continue}
                $group='database|'+$record.host+'|'+$record.database+'|'+$record.operation
                $status=if($record.completed){'passed'}else{'failed'}
            }
            'test' {
                if($record.schema_version -ne 1 -or -not $record.checks){continue}
                $finished=$record.completed_utc;$status=$record.selected_checks_verdict
                $group='test|desktop'
            }
            'components' {
                if($record.schema -ne 'laplace.windows-components/v1' -or $record.plan -ne $false -or -not $record.components){continue}
                $group='components|desktop'
                $status='passed';$finished=(Get-Item -LiteralPath $receipt).LastWriteTimeUtc.ToString('o')
            }
            'storage' {$group='storage'}
            'development' {
                if(-not $record.source -or -not $record.build_root -or $record.operation -notin @('build','test')){continue}
                $group='development|desktop|'+$record.operation
            }
            'desktop-run' {
                if(-not $record.source -or -not $record.base_url -or -not $record.build_root){continue}
                $group='desktop-run|'+$record.base_url
                if($status -in @('verified','stopped')){$status='passed'}
            }
            'desktop-verification' {
                if(-not $record.source -or -not $record.url -or -not $record.run_directory){continue}
                $group='desktop-verification|'+$record.url
                if($status -eq 'verified'){$status='passed'}
            }
        }
        if(-not $group -or -not $finished -or $status -notin @('passed','failed','installed_pending_reconnect')){continue}
        # PowerShell 7.5+ deserializes ISO timestamps into DateTime. Parsing
        # their culture-formatted string would discard the offset a second time.
        try {
            $time=if($finished -is [DateTime]){$finished.ToUniversalTime()}
                elseif($finished -is [DateTimeOffset]){$finished.UtcDateTime}
                else{[DateTimeOffset]::Parse($finished).UtcDateTime}
        }catch{continue}
        $reasons=@()
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){$reasons+='reparse_point'}
        if(Test-StorageReference $item.FullName $References $Processes){$reasons+='live_reference'}
        if($item.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $item.FullName '.retain'))){$reasons+='operator_retained'}
        if($family -eq 'test') {
            foreach($scratch in Get-ChildItem -LiteralPath $item.FullName -Directory -Filter '*-scratch') {
                if($scratch.Attributes -band [IO.FileAttributes]::ReparsePoint){$reasons+='reparse_point';continue}
                try {$lease=Read-StorageJson (Join-Path $scratch.FullName '.laplace-scratch.json')}catch{continue}
                if($lease.schema -eq 'laplace.acceptance-scratch/v1' -and $lease.owner_pid -gt 0 -and
                    [IO.Path]::IsPathFullyQualified([string]$lease.receipt) -and
                    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($lease.receipt)) -ieq $item.FullName -and
                    $scratch.Name -ceq ($lease.check+'-scratch') -and (Test-StorageLeaseOwner $lease $Processes)) {
                    $reasons+='live_owner';break
                }
            }
        }
        if(([DateTime]::UtcNow-$time).TotalMinutes -lt 5){$reasons+='recent_run'}
        $entry=[pscustomobject]@{path=$item.FullName;root=[IO.Path]::GetFullPath($Root);kind='operation_history';
            marker=$marker;revision=$null;modified_utc=$time.ToString('o');reasons=$reasons;retire=$false;
            history_group=$group;history_status=$status;receipt_path=$receipt;receipt_sha256=(Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash}
        $entries+=$entry;$records[$item.FullName]=$record
    }
    foreach($group in $entries|Group-Object history_group) {
        $success=0;$failure=0
        foreach($entry in $group.Group|Sort-Object modified_utc -Descending) {
            if($entry.reasons.Count){continue}
            # A cleanup writes the next storage receipt after retirement.
            $keep=if($entry.history_group -eq 'storage'){[Math]::Max(1,$Successes-1)}else{$Successes}
            if($entry.history_status -eq 'failed') {
                if($failure++ -lt $Failures){$entry.reasons+='recent_failure'}else{$entry.retire=$true}
            } elseif($success++ -lt $keep){$entry.reasons+='recent_success'}else{$entry.retire=$true}
        }
    }
    foreach($entry in $entries|Where-Object retire) {
        if(Test-Path -LiteralPath $entry.path -PathType Container) {
            $tree=@(Get-ChildItem -LiteralPath $entry.path -Recurse -Force -ErrorAction Stop)
            if(@($tree|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {
                $entry.retire=$false;$entry.reasons+='reparse_point'
            }
            if(@($tree|Where-Object Name -EQ '.git').Count) {
                $entry.retire=$false;$entry.reasons+='source_checkout'
            }
        }
    }
    # Follow explicit receipt links from retained runs, not paths merely listed
    # in old inventories. The latter would pin all historical output forever.
    do {
        $linked=@($References)
        foreach($entry in $entries|Where-Object {-not $_.retire}) {$linked+=@(Get-StorageReceiptReferences $records[$entry.path])}
        $changed=$false
        foreach($entry in $entries|Where-Object retire) {
            if(Test-StorageReference $entry.path $linked @()) {$entry.retire=$false;$entry.reasons+='retained_receipt_reference';$changed=$true}
        }
    } while($changed)
    return $entries
}

function Get-StorageGroup([string]$Root, [string]$Marker, [string]$Kind, [int]$Keep,
                          [string[]]$References, [object[]]$Processes, [string[]]$Revisions=@(), [bool]$Unobservable=$false) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $entries = @()
    foreach ($directory in Get-ChildItem -LiteralPath $Root -Directory -Force) {
        if ($directory.Name -notmatch '^[a-f0-9]{40,64}$') { continue }
        $manifest = Read-StorageJson (Join-Path $directory.FullName $Marker)
        if (-not $manifest -or -not $manifest.files) { continue }
        $reasons = @()
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { $reasons += 'reparse_point' }
        if (Test-StorageReference $directory.FullName $References $Processes) { $reasons += 'live_reference' }
        if ($manifest.revision -and $manifest.revision -in $Revisions) { $reasons += 'retained_release' }
        if ($Unobservable) { $reasons += 'process_visibility_incomplete' }
        $entries += [pscustomobject]@{path=$directory.FullName;root=[IO.Path]::GetFullPath($Root);kind=$Kind;
            marker=$Marker;revision=$manifest.revision;modified_utc=$directory.LastWriteTimeUtc.ToString('o');reasons=$reasons;retire=$false}
    }
    $retained = 0
    foreach ($entry in @($entries | Sort-Object modified_utc -Descending)) {
        if ($entry.reasons.Count) { continue }
        if ($retained -lt $Keep) { $entry.reasons += 'rollback_or_reuse'; $retained++ }
        else { $entry.retire = $true }
    }
    return $entries
}

function Get-StorageUciInstallation($Iis) {
    $development=Read-StorageJson (Join-Path $PSScriptRoot '../development/installation.json')
    if(-not $development.uci){return $null}
    $service=[string]$development.uci.service
    if($service -notmatch '^[a-zA-Z0-9-]+$'){throw 'Invalid declared UCI service for storage retention.'}
    $root=Join-Path (Split-Path -Parent $Iis.directory) $service
    $installed=Read-StorageJson (Join-Path $root 'agent/installation.json')
    if(-not $installed){return $null}
    $release=Join-Path $root ('releases/'+$installed.revision)
    if($installed.host -ine $env:COMPUTERNAME -or $installed.site -cne $service -or
       $installed.revision -notmatch '^[a-f0-9]{7,64}$' -or
       [IO.Path]::GetFullPath($installed.directory) -ine [IO.Path]::GetFullPath($root) -or
       [IO.Path]::GetFullPath($installed.publish) -ine [IO.Path]::GetFullPath($release) -or
       -not(Test-Path -LiteralPath (Join-Path $release 'laplace-uci-connect.exe') -PathType Leaf)){
        throw 'Installed UCI selection differs from its declared service and release root.'
    }
    return @{root=$root;release=$release;site=$service}
}

function Get-StorageUciPayload([string]$Directory) {
    Assert-StorageTree $Directory (Split-Path -Parent $Directory)
    $files=@(Get-ChildItem -LiteralPath $Directory -Recurse -File|Where-Object Name -NotIn @('web.config','uci-package.json')|Sort-Object FullName)
    $entries=@($files|ForEach-Object {[IO.Path]::GetRelativePath($Directory,$_.FullName).Replace('\','/')+':'+(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()})
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($entries -join "`n"))).ToLowerInvariant()
}

function Get-StorageUciReleases($Uci,[int]$Keep,[string[]]$References,[object[]]$Processes,[bool]$Unobservable) {
    $root=Join-Path $Uci.root 'releases'
    $entries=@(Get-StorageGroup $root 'uci-package.json' 'uci_release' 0 $References $Processes @() $Unobservable)
    foreach($directory in Get-ChildItem -LiteralPath $root -Directory){
        if($directory.Name -notmatch '^[a-f0-9]{7,64}$' -or (Test-Path -LiteralPath (Join-Path $directory.FullName 'uci-package.json'))){continue}
        $webConfig=Join-Path $directory.FullName 'web.config'
        $assembly=Join-Path $directory.FullName 'laplace-uci-connect.dll'
        if(-not(Test-Path -LiteralPath $webConfig) -or -not(Test-Path -LiteralPath $assembly)){continue}
        try{
            $xml=[xml](Get-Content -LiteralPath $webConfig -Raw)
            $handler=$xml.configuration.'system.webServer'.aspNetCore
            if($handler.processPath -cne '.\laplace-uci-connect.exe' -or
               $handler.arguments -cne ('serve --configuration "'+(Join-Path $Uci.root 'connector.json')+'"')){continue}
            $digest=Get-StorageUciPayload $directory.FullName
        }catch{continue}
        # Earlier publishers used either this same payload hash or the exact
        # source commit embedded in the assembly. Do not adopt arbitrary folders.
        if($directory.Name.Length -eq 64){if($directory.Name -cne $digest){continue}}
        else{
            $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($assembly).ProductVersion
            if($version -notmatch '\+([a-f0-9]{40})$' -or -not $Matches[1].StartsWith($directory.Name)){continue}
        }
        $reasons=@()
        if(Test-StorageReference $directory.FullName $References $Processes){$reasons+='live_reference'}
        if($Unobservable){$reasons+='process_visibility_incomplete'}
        $entries += [pscustomobject]@{path=$directory.FullName;root=[IO.Path]::GetFullPath($root);kind='uci_release';marker=$null;
            revision=$directory.Name;modified_utc=$directory.LastWriteTimeUtc.ToString('o');reasons=$reasons;retire=($reasons.Count -eq 0);uci_payload_sha256=$digest}
    }
    $retained=0
    foreach($entry in @($entries|Where-Object {$_.reasons.Count -eq 0}|Sort-Object modified_utc -Descending)){
        if($retained++ -lt $Keep){$entry.retire=$false;$entry.reasons+='rollback_or_reuse'}
    }
    return $entries
}

function Get-DesktopStoragePlan {
    param([Parameter(Mandatory)][string]$WorkRoot, [Parameter(Mandatory)][string]$BuildRoot,
          [Parameter(Mandatory)]$Modular, [Parameter(Mandatory)]$Iis,
          [object[]]$Processes, [ValidateRange(0,10)][int]$Rollback=1, [string[]]$DatabaseReferences, [string[]]$BuildReferences)
    if (-not $PSBoundParameters.ContainsKey('Processes')) { $Processes = @(Get-StorageProcesses) }
    if (-not $PSBoundParameters.ContainsKey('DatabaseReferences')) { $DatabaseReferences = @(Get-StorageDatabaseReferences) }
    if (-not $PSBoundParameters.ContainsKey('BuildReferences')) { $BuildReferences = @(Get-StorageBuildReferences $BuildRoot) }
    if ([IO.Path]::GetFullPath($Modular.artifacts).TrimEnd('\','/') -ine
        [IO.Path]::GetFullPath((Join-Path $WorkRoot 'artifacts/windows-components')).TrimEnd('\','/')) {
        throw 'The component store must use the declared work root.'
    }
    $installed = Read-StorageJson $Modular.installed_config
    $web = Join-Path $Iis.directory 'web'
    $active = Read-StorageJson (Join-Path $web 'active.json')
    if (-not $installed.release -or -not $active.revision) { throw 'Installed modular and IIS selections are required for storage retirement.' }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($installed.release)) -ine
        [IO.Path]::GetFullPath((Join-Path $Modular.prefix 'releases')) -or $active.revision -notmatch '^[a-f0-9]{40,64}$' -or
        -not (Read-StorageJson (Join-Path $installed.release 'package.json')) -or
        -not (Read-StorageJson (Join-Path $web ('releases/'+$active.revision+'/iis-package.json')))) {
        throw 'Installed selections must identify existing packages in their declared release roots.'
    }
    $references = @([string]$installed.release, (Join-Path $web ('releases/'+$active.revision))) + $DatabaseReferences
    # API clients can deliberately pin a connector independently of its IIS
    # service. Keep that real consumer reference until the client is updated.
    if($Iis.chess.match_engines.connector){$references += [string]$Iis.chess.match_engines.connector}
    $uci=Get-StorageUciInstallation $Iis
    if($uci){$references += $uci.release}
    $webConfig = Join-Path $web 'web.config'
    if (Test-Path -LiteralPath $webConfig) {
        $xml = [xml](Get-Content -LiteralPath $webConfig -Raw)
        $processPath = [string]$xml.configuration.'system.webServer'.aspNetCore.processPath
        if ($processPath) { $references += [IO.Path]::GetFullPath((Join-Path $web $processPath)) }
    }
    $unknown = @($Processes | Where-Object {-not $_.executable -and $_.name -in @('lpm.exe','laplace.exe')}).Count -gt 0
    $unknownIis = @($Processes | Where-Object {
        (-not $_.executable -and ($_.name -in @('w3wp.exe','dotnet.exe') -or $_.name -like 'Laplace.*.exe')) -or $_.module_error
    }).Count -gt 0
    $entries = @(Get-StorageGroup (Join-Path $Modular.prefix 'releases') 'package.json' 'modular_release' $Rollback $references $Processes @() $unknown)
    $entries += @(Get-StorageGroup (Join-Path $web 'releases') 'iis-package.json' 'iis_release' $Rollback $references $Processes @() $unknownIis)
    if($uci){
        # During an overlapped IIS recycle, an old managed assembly may not
        # appear in the native module inventory. Wait for the old worker to exit.
        $workers=@($Processes|Where-Object {$_.name -eq 'w3wp.exe' -and $_.command -match ('-ap\s+"?'+[regex]::Escape($uci.site)+'(?:"|\s|$)')})
        $entries += @(Get-StorageUciReleases $uci $Rollback $references $Processes ($unknownIis -or $workers.Count -gt 1))
    }
    $revisions = @($entries | Where-Object {-not $_.retire -and $_.revision} | ForEach-Object revision)
    $packages = Join-Path $WorkRoot 'artifacts/iis-packages'
    $entries += @(Get-StorageGroup $packages 'iis-package.json' 'iis_package' 2 $references $Processes $revisions $unknownIis)
    $keptPackages = @($entries | Where-Object {$_.kind -eq 'iis_package' -and -not $_.retire} | ForEach-Object path)
    $componentReferences = @($references)
    $compositions = Join-Path $WorkRoot 'artifacts/iis-compositions'
    if (Test-Path -LiteralPath $compositions) {
        foreach ($file in Get-ChildItem -LiteralPath $compositions -Filter '*.json' -File) {
            $composition = Read-StorageJson $file.FullName
            if ($composition.package -in $keptPackages) {
                foreach ($component in $composition.inputs.components) {
                    if ($component.component -in @('api','cli','uci','migrations')) {
                        $componentReferences += Join-Path $Modular.artifacts ($component.component+'/'+$component.identity)
                    }
                }
            }
        }
    }
    foreach ($component in 'api','cli','uci','migrations') {
        $entries += @(Get-StorageGroup (Join-Path $Modular.artifacts $component) 'artifact.json' 'component' 2 $componentReferences $Processes @() ($unknown -or $unknownIis))
    }
    # Earlier packaging kept two complete trees per run. Keep its logs and
    # receipts, but retire those payloads once their release is no longer kept.
    $legacy = Join-Path $WorkRoot 'iis-packages'
    if (Test-Path -LiteralPath $legacy) {
        foreach ($bundle in Get-ChildItem -LiteralPath $legacy -Directory) {
            if ($bundle.Name -notmatch '^[a-f0-9]{40}(?:-[a-f0-9]{32})?$') { continue }
            $manifest = Read-StorageJson (Join-Path $bundle.FullName 'package/iis-package.json')
            foreach ($leaf in 'published','package') {
                $path = Join-Path $bundle.FullName $leaf
                if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
                $reasons = @()
                if ($manifest.revision -in $revisions) { $reasons += 'retained_release' }
                if ($unknownIis) { $reasons += 'process_visibility_incomplete' }
                if (Test-StorageReference $bundle.FullName $references $Processes) { $reasons += 'live_reference' }
                $entries += [pscustomobject]@{path=$path;root=$bundle.FullName;kind='legacy_iis_payload';
                    marker=$null;revision=$manifest.revision;modified_utc=$bundle.LastWriteTimeUtc.ToString('o');reasons=$reasons;retire=($reasons.Count -eq 0)}
            }
        }
    }
    $protected=@($references)+$BuildReferences+@([string]$Modular.build,[string]$Modular.mcp_build)
    $entries+=@(Get-StorageScratch (Join-Path $BuildRoot 'worktrees') '^[a-z0-9_-]+-[a-f0-9]{12}$' 'abandoned_build' $protected $Processes)
    $entries+=@(Get-StorageScratch (Join-Path $Modular.prefix 'releases') '^(?:\.package-[\w-]+|\.stale-[\w.-]+|[a-f0-9]{64}-\d+)$' 'abandoned_scratch' $protected $Processes)
    foreach($component in 'api','cli','uci','migrations') {
        $entries+=@(Get-StorageScratch (Join-Path $Modular.artifacts $component) '^(?:\.publish-[\w-]+|[a-f0-9]{64}\.replaced)$' 'abandoned_scratch' $protected $Processes)
    }
    $operations=Join-Path $WorkRoot 'operations'
    if(Test-Path -LiteralPath $operations) {
        foreach($run in Get-ChildItem -LiteralPath $operations -Directory | Where-Object Name -Match '^components-\d{8}T\d{6,13}Z$') {
            $entries+=@(Get-StorageScratch $run.FullName '^published$' 'abandoned_scratch' $protected $Processes)
        }
        foreach($run in Get-ChildItem -LiteralPath $operations -Directory | Where-Object Name -Match '^test-\d{8}T\d{6,13}Z$') {
            foreach($entry in @(Get-StorageScratch $run.FullName '^[a-z0-9][a-z0-9_-]*-scratch$' 'acceptance_scratch' $protected $Processes)) {
                if ('reparse_point' -in $entry.reasons) { continue }
                $marker='.laplace-scratch.json'
                $lease=Read-StorageJson (Join-Path $entry.path $marker)
                if (-not $lease -or $lease.schema -ne 'laplace.acceptance-scratch/v1' -or
                    $lease.owner_pid -le 0 -or -not [IO.Path]::IsPathFullyQualified([string]$lease.receipt) -or
                    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($lease.receipt)) -ine $run.FullName -or
                    [IO.Path]::GetFileName($entry.path) -cne ($lease.check+'-scratch')) { continue }
                # A dead runner can leave a child finishing cleanup. Follow its
                # descendants too, even when the parent PID has already exited.
                if (Test-StorageLeaseOwner $lease $Processes) { $entry.reasons+='live_owner';$entry.retire=$false }
                $entry.marker=$marker
                $entries+=$entry
            }
        }
    }
    $heldScratch=@($entries|Where-Object {$_.kind -eq 'acceptance_scratch' -and -not $_.retire}|ForEach-Object path)
    $entries+=@(Get-StorageOperationHistory -Root $operations -Processes $Processes -References (@($protected)+$heldScratch))
    $historyRoots=@($entries|Where-Object {$_.kind -eq 'operation_history' -and $_.retire}|ForEach-Object path)
    foreach($entry in $entries|Where-Object {$_.retire -and $_.kind -ne 'operation_history'}) {
        foreach($parent in $historyRoots) {
            if($entry.path.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)) {
                $entry.retire=$false;$entry.reasons+='collected_with_run';break
            }
        }
    }
    [ordered]@{schema='laplace.desktop-storage/v1';checked_utc=[DateTime]::UtcNow.ToString('o');
        build_root=[IO.Path]::GetFullPath($BuildRoot);work_root=[IO.Path]::GetFullPath($WorkRoot);
        policy=@{rollback_releases=$Rollback;reusable_components=2;reusable_packages=2;operation_successes=3;operation_failures=1};entries=$entries;database_references=$DatabaseReferences;
        source_and_build_policy='Keep source checkouts, registered worktree builds and declared incremental build profiles. Retire abandoned generated worktree builds and publisher scratch.'}
}

. "$PSScriptRoot/storage-cleanup.ps1"

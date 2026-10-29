#Requires -Version 7
param(
    [string[]]$Check,
    [string]$Output,
    [string]$Manifest = "$PSScriptRoot/criteria.json",
    [switch]$List
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$registry = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json -Depth 40
if ($registry.schema_version -ne 1) { throw 'Unsupported acceptance schema' }
$platform = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } else { 'other' }
$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$criteriaIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($criterion in $registry.criteria) {
    if (-not $criterion.id -or -not $criteriaIds.Add($criterion.id)) { throw 'Missing or duplicate criterion ID' }
    if (-not $criterion.owner -or -not $criterion.outcome -or @($criterion.checks).Count -eq 0) {
        throw "Incomplete criterion: $($criterion.id)"
    }
    foreach ($item in $criterion.checks) {
        if (-not $item.id -or -not $ids.Add($item.id)) { throw 'Missing or duplicate check ID' }
        if ($item.id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Check ID is not a safe evidence directory name.' }
        if ($item.platform -notin 'windows','linux','any') { throw "Invalid platform: $($item.id)" }
        if ($null -ne $item.argv -and (@($item.argv).Count -lt 1 -or -not $item.argv[0] -or $item.timeout_seconds -le 0)) {
            throw "Invalid command: $($item.id)"
        }
    }
}
foreach ($criterion in $registry.criteria) {
    foreach ($dependency in $criterion.depends_on) {
        if (-not $criteriaIds.Contains($dependency)) { throw "Unknown dependency: $dependency" }
    }
}
if ($List) {
    foreach ($criterion in $registry.criteria) {
        foreach ($item in $criterion.checks) {
            '{0,-24} {1,-28} {2,-8} {3}' -f $criterion.id, $item.id, $item.platform,
                $(if ($null -eq $item.argv) { 'NOT IMPLEMENTED' } else { $item.argv -join ' ' })
        }
    }
    exit 0
}
if (-not $Output) { throw '-Output is required so every run has a persistent receipt' }
$outputPath = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $outputPath) { throw "Refusing to replace an existing receipt: $outputPath" }
$selectedIds = @($Check | ForEach-Object { $_ -split ',' } | ForEach-Object {$_.Trim()} | Where-Object { $_ })
if ($PSBoundParameters.ContainsKey('Check') -and -not $selectedIds.Count) { throw '-Check requires at least one registered check ID.' }
foreach ($id in $selectedIds) { if (-not $ids.Contains($id)) { throw "Unknown check: $id" } }

function RunCheck($item) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $item.argv[0]
    foreach ($argument in @($item.argv | Select-Object -Skip 1)) { $info.ArgumentList.Add([string]$argument) }
    $info.WorkingDirectory = $repo
    # A check's transient payload belongs to its receipt, never an agent's
    # manually selected audit directory. Child owners still release their own
    # databases and processes; this runner retires only its own scratch tree.
    $scratch=$null
    if ($item.scratch) {
        if ($item.id -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw 'Scratch check ID is not a directory name.' }
        $scratch=Join-Path (Split-Path $outputPath -Parent) ($item.id+'-scratch')
        if (Test-Path -LiteralPath $scratch) { throw "Scratch already exists: $scratch" }
        [void][IO.Directory]::CreateDirectory($scratch)
        foreach ($name in 'TMPDIR','TMP','TEMP','LAPLACE_ACCEPTANCE_WORK') { $info.Environment[$name]=$scratch }
        $info.Environment['LAPLACE_ACCEPTANCE_RESULTS']=Join-Path (Split-Path $outputPath -Parent) $item.id
        $lease=@{schema='laplace.acceptance-scratch/v1';owner_pid=$PID;child_pid=0;receipt=$outputPath;check=$item.id}
        $leasePath=Join-Path $scratch '.laplace-scratch.json'
        [IO.File]::WriteAllText($leasePath+'.next',($lease|ConvertTo-Json))
        [IO.File]::Move($leasePath+'.next',$leasePath,$true)
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $began = [DateTime]::UtcNow
    $status = 'failed'; $code = $null; $stdout = ''; $stderr = ''
    try {
        [void]$process.Start()
        if ($scratch) {
            $lease.child_pid=$process.Id
            [IO.File]::WriteAllText($leasePath+'.next',($lease|ConvertTo-Json))
            [IO.File]::Move($leasePath+'.next',$leasePath,$true)
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([int]$item.timeout_seconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            $status = 'timed_out'
        } else {
            $code = $process.ExitCode
            if ($code -eq 0) { $status = 'passed' }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    } catch { $stderr = $_.Exception.Message }
    finally {
        $process.Dispose()
        if ($scratch -and (Test-Path -LiteralPath $scratch)) {
            try {
                . "$repo/installation/storage.ps1"
                Assert-StorageTree $scratch (Split-Path $outputPath -Parent)
                Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop
            } catch { $status='failed'; $stderr+=[Environment]::NewLine+'Scratch cleanup failed: '+$_.Exception.Message }
        }
    }
    [ordered]@{
        status = $status; exit_code = $code; started_utc = $began.ToString('o')
        duration_seconds = [math]::Round(([DateTime]::UtcNow - $began).TotalSeconds, 3)
        stdout = $stdout; stderr = $stderr
        scratch_removed = (-not $scratch -or -not (Test-Path -LiteralPath $scratch))
    }
}

$started = [DateTime]::UtcNow
$revision = & git -C $repo rev-parse HEAD
if ($LASTEXITCODE) { throw 'Cannot identify the source revision' }
$dirtyBefore = @(& git -C $repo status --porcelain)
$results = @()
foreach ($criterion in $registry.criteria) {
    foreach ($item in $criterion.checks) {
        $selected = $selectedIds.Count -eq 0 -or $item.id -cin $selectedIds
        $result = [ordered]@{
            criterion = $criterion.id; check = $item.id; platform = $item.platform
            selected = $selected; evidence_scope = $item.evidence; argv = $item.argv
            status = 'not_selected'
        }
        if ($selected) {
            if ($null -eq $item.argv) { $result.status = 'not_implemented' }
            elseif ($item.platform -ne 'any' -and $item.platform -ne $platform) { $result.status = 'wrong_platform' }
            else {
                $execution = RunCheck $item
                foreach ($key in $execution.Keys) { $result[$key] = $execution[$key] }
                $details=Join-Path (Split-Path $outputPath -Parent) $item.id
                [void][IO.Directory]::CreateDirectory($details)
                [IO.File]::WriteAllText((Join-Path $details 'stdout.log'),$execution.stdout)
                [IO.File]::WriteAllText((Join-Path $details 'stderr.log'),$execution.stderr)
                $result.evidence_directory=$details
                [IO.File]::WriteAllText((Join-Path $details 'execution.json'),($result|ConvertTo-Json -Depth 15))
            }
            '{0}: {1}' -f $item.id, $result.status
            if ($result.evidence_directory) { "Evidence: $($result.evidence_directory)" }
        }
        $results += $result
    }
}
$selectedResults = @($results | Where-Object selected)
$verdict = if (@($selectedResults | Where-Object status -In 'failed','timed_out').Count) { 'failed' }
    elseif ($selectedResults.Count -eq 0 -or @($selectedResults | Where-Object status -NE 'passed').Count) { 'incomplete' }
    else { 'passed' }
$unproved = @($results | Where-Object status -NE 'passed')
$receipt = [ordered]@{
    schema_version = 1; started_utc = $started.ToString('o'); completed_utc = [DateTime]::UtcNow.ToString('o')
    host = [Environment]::MachineName; platform = $platform; source_revision = "$revision"
    worktree_dirty_before = ($dirtyBefore.Count -gt 0)
    worktree_dirty_after = (@(& git -C $repo status --porcelain).Count -gt 0)
    registry_sha256 = (Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    github_run_id = $env:GITHUB_RUN_ID; tracker = $registry.tracker
    scope = $(if ($selectedIds.Count) { 'selected checks only' } else { 'all registered checks' })
    selected_checks_verdict = $verdict
    installation_verdict = $(if ($unproved.Count) { 'incomplete' } else { 'all registered checks passed; review operational evidence' })
    checks_without_passing_evidence = @($unproved | ForEach-Object check)
    checks = $results
}
$directory = Split-Path $outputPath -Parent
[void][IO.Directory]::CreateDirectory($directory)
[IO.File]::WriteAllText($outputPath, ($receipt | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
"Receipt: $outputPath"
"Selected checks: $verdict; installation: $($receipt.installation_verdict)"
if ($verdict -eq 'failed') { exit 1 }
if ($verdict -eq 'incomplete') { exit 2 }
exit 0

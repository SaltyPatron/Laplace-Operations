#Requires -Version 7
<#
  One set of HART-DESKTOP's copy-off to hart-server (jobs.psd1): for each job, a SHA-256 manifest of every file to copy
  is written on this machine first (hash-manifest.ps1: relative path, size, sha256; then a totals line), then robocopy
  copies it, restartable: identical files are skipped. hart-server re-hashes what landed and diffs it against the
  manifest. Never /MIR, /PURGE or /MOV: nothing on either side is ever deleted or moved.

    pwsh -File backup\copyoff.ps1 -Set D [-Only name,...] [-ManifestOnly] [-SkipManifest] [-Models]

  -Models: the Models-* jobs, which are on hold without it ("don't touch the models", 2026-10-07). Exit 3: a job does
  not fit on hart-server and nothing more is copied; exit 4: a manifest failed.
#>
param([Parameter(Mandatory)][string]$Set, [string[]]$Only, [switch]$ManifestOnly, [switch]$SkipManifest, [switch]$Models)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\laplace.env.ps1"
$conf = Import-PowerShellDataFile $env:LAPLACE_BACKUP_JOBS
$s = $conf.Sets | Where-Object Name -eq $Set | Select-Object -First 1
if (-not $s) { "no set $Set in $($env:LAPLACE_BACKUP_JOBS)"; exit 2 }
$logs = if ($s.Logs) { Join-Path $env:LAPLACE_BACKUP_LOGS $s.Logs } else { $env:LAPLACE_BACKUP_LOGS }
New-Item -ItemType Directory -Force "$logs\manifests", "$logs\robocopy", "$logs\patches" | Out-Null
$inbox = $s.Inbox
function Dest([string]$p) { if ($p.StartsWith('\\')) { $p } else { Join-Path $inbox $p } }
$jobs = @($s.Jobs | ForEach-Object { $j = $_.Clone(); $j.d = Dest $j.d; if ($j.man) { $j.man = Dest $j.man }; $j })

function Write-Manifest($job) {
  # hash-manifest.ps1 (compiled C#, 8 workers) streams the rows to <tsv>.part and writes the sorted manifest at the end (the
  # PowerShell -Parallel pipeline died silently on 315k files, three times)
  $tsv = "$logs\manifests\$($job.n).tsv"
  $xd = @($job.xd | Where-Object { $_ }); $xf = @($job.xf | Where-Object { $_ })
  $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\hash-manifest.ps1", '-Root', $job.s, '-Out', $tsv)
  if ($xd) { $pa += '-Xd'; $pa += ($xd -join ',') }; if ($xf) { $pa += '-Xf'; $pa += ($xf -join ',') }
  Write-Host ("{0,-26} hashing  {1}" -f $job.n, (Get-Date -Format s))
  & pwsh @pa 2>&1 | ForEach-Object { Write-Host ("{0,-26}{1}" -f $job.n, "$_") }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tsv)) { Write-Host "STOP: $($job.n) manifest failed (exit $LASTEXITCODE)"; exit 4 }
  $last = Get-Content $tsv -Tail 1
  Write-Host ("{0,-26} manifest: {1}" -f $job.n, $last)
}
# Room on hart-server for what the job still has to copy, plus 5 GiB; the run stops if it won't fit (XFS full is never
# acceptable). Each share is the mount jobs.psd1 names for it.
function Assert-Room($job) {
  $u = $job.d -replace '^\\\\[^\\]+\\', ''; $share, $rest = $u -split '\\', 2
  $mount = $conf.Mounts[$share]
  if (-not $mount) { Write-Host "STOP: $($job.n): no mount for the share $share in jobs.psd1"; exit 3 }
  $path = ($mount + '/' + ($rest -replace '\\', '/')).TrimEnd('/')
  $tsv = "$logs\manifests\$($job.n).tsv"
  $total = if (Test-Path $tsv) { [int64]((Get-Content $tsv -Tail 1) -replace '.*bytes=', '') } else { (Get-ChildItem $job.s -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
  # @() keeps one line of output an array: a bare string's [0] is its first character
  $q = @(& ssh.exe -i $env:LAPLACE_PEER_KEY -o BatchMode=yes $env:LAPLACE_PEER "df -B1 --output=avail '$mount' | tail -1; du -sb '$path' 2>/dev/null | cut -f1 || echo 0")
  $avail = [int64]$q[0]; $have = if ($q.Count -gt 1 -and $q[1]) { [int64]$q[1] } else { 0 }
  $need = [math]::Max([int64]0, [int64]$total - $have) + 5GB
  Write-Host ("{0,-26} room: needs {1:N1} GiB (+5), {2:N1} GiB free on {3}" -f $job.n, (($need - 5GB)/1GB), ($avail/1GB), $mount)
  if ($need -gt $avail) { Write-Host "STOP: $($job.n) does not fit on $mount; nothing more is copied"; exit 3 }
}
function Copy-Job($job) {
  Assert-Room $job
  $log = "$logs\robocopy\$($job.n).log"
  $ra = @($job.s, $job.d, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/FFT', '/R:2', '/W:5', '/MT:8', '/NP', "/UNILOG+:$log")
  $xd = @($job.xd | Where-Object { $_ }); if ($xd) { $ra += '/XD'; $ra += $xd }
  $xf = @($job.xf | Where-Object { $_ }); if ($xf) { $ra += '/XF'; $ra += $xf }
  & robocopy.exe @ra | Out-Null; $rc = $LASTEXITCODE
  Write-Host ("{0,-26} robocopy exit {1} ({2})" -f $job.n, $rc, $(if ($rc -lt 8) { 'ok' } else { 'FAILED: see ' + $log }))
}

# the uncommitted edits in the dependency sources (LAPLACE_DEPSRC), kept as patches: the sources themselves are reinstalled
if ($s.Patches) {
  foreach ($r in Get-ChildItem $env:LAPLACE_DEPSRC -Directory) { if (Test-Path "$($r.FullName)\.git") {
    $st = git -C $r.FullName status --porcelain 2>$null; if ($st) { git -C $r.FullName diff > "$logs\patches\$($r.Name).patch"; $st | Set-Content "$logs\patches\$($r.Name).status.txt" } } }
}

foreach ($job in $jobs) {
  if ($Only -and $job.n -notin $Only) { continue }
  if ($job.n -like 'Models-*' -and -not $Models) { "{0,-26} on hold: models are not touched without -Models" -f $job.n; continue }
  if (-not (Test-Path $job.s)) { "{0,-26} (no source)" -f $job.n; continue }
  $m = if ($job.man) { $job.man } else { "$inbox\_manifest" }
  if (-not $SkipManifest) { Write-Manifest $job }
  if (-not ($ManifestOnly -or $job.manifestOnly)) { Copy-Job $job }
  if (Test-Path "$logs\manifests\$($job.n).tsv") { New-Item -ItemType Directory -Force $m | Out-Null; Copy-Item "$logs\manifests\$($job.n).tsv" $m -Force }
}
if ($s.Patches -and (Get-ChildItem "$logs\patches" -File -ErrorAction SilentlyContinue)) { New-Item -ItemType Directory -Force "$inbox\_patches" | Out-Null; Copy-Item "$logs\patches\*" "$inbox\_patches" -Force }

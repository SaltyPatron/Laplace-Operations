#Requires -Version 7
<#
  One set of HART-DESKTOP's copy-off to hart-server (jobs.psd1): for each job, a SHA-256 manifest of every file to copy
  is written on this machine first (hash-manifest.ps1: relative path, size, sha256; then a totals line), then robocopy
  copies it, restartable: identical files are skipped. Every manifested destination file is checked for size and
  SHA-256 before success is recorded. Never /MIR, /PURGE or /MOV: no source or destination content is deleted.

    pwsh -File backup\copyoff.ps1 -Set D [-Only name,...] [-ManifestOnly] [-SkipManifest] [-Models]

  -Models: opt in to the held Models-* jobs. -Plan lists resolved paths without copying. Failures exit nonzero.
  -Fresh remains accepted for existing callers; every run now refreshes changed source files.
#>
param([Parameter(Mandatory)][string]$Set, [string[]]$Only, [switch]$ManifestOnly, [switch]$SkipManifest, [switch]$Fresh, [switch]$Models, [switch]$Plan)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\laplace.env.ps1"
. "$PSScriptRoot\config.ps1"
$conf = Read-BackupConfiguration $env:LAPLACE_BACKUP_JOBS
$s = $conf.Sets | Where-Object Name -eq $Set | Select-Object -First 1
if (-not $s) { "no set $Set in $($env:LAPLACE_BACKUP_JOBS)"; exit 2 }
$logs = if ($s.Logs) { Join-Path $env:LAPLACE_BACKUP_LOGS $s.Logs } else { $env:LAPLACE_BACKUP_LOGS }
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
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tsv)) { throw "$($job.n) manifest failed (exit $LASTEXITCODE)" }
  $last = Get-Content $tsv -Tail 1
  Write-Host ("{0,-26} manifest: {1}" -f $job.n, $last)
}
# Conservatively reserve the source manifest's size plus 5 GiB; the run stops if it won't fit (XFS full is never
# acceptable). Each share is the mount jobs.psd1 names for it.
# ssh with stdin closed (-n) and bounded: under a headless task Windows' ssh.exe can finish the remote command and never
# exit. Each try gets 90 s and is killed past it; only a successful completed probe counts; three tries.
function Probe([string]$key, [string]$peer, [string]$cmd) {
  for ($try = 1; $try -le 3; $try++) {
    $psi = [Diagnostics.ProcessStartInfo]::new('ssh.exe')
    foreach ($a in '-n', '-i', $key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4', $peer, $cmd) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi); $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(90000)) { try { $p.Kill($true) } catch {} }
    [void]$out.Wait(5000)
    if ($p.HasExited -and $p.ExitCode -eq 0 -and $out.IsCompletedSuccessfully) {
      $lines = @("$($out.Result)" -split "`n" | ForEach-Object Trim | Where-Object { $_ })
      if ($lines.Count) { return $lines }
    }
    Write-Host "  room probe try $try gave nothing"; Start-Sleep -Seconds 10
  }
  @()
}
function Assert-Room($job) {
  $u = $job.d -replace '^\\\\[^\\]+\\', ''; $share, $rest = $u -split '\\', 2
  $mount = $conf.Mounts[$share]
  if (-not $mount) { throw "$($job.n): no mount for the share $share in jobs.psd1" }
  $path = ($mount + '/' + ($rest -replace '\\', '/')).TrimEnd('/')
  $tsv = "$logs\manifests\$($job.n).tsv"
  $total = if (Test-Path $tsv) { [int64]((Get-Content $tsv -Tail 1) -replace '.*bytes=', '') } else { (Get-ChildItem $job.s -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
  $q = @(Probe $env:LAPLACE_PEER_KEY $env:LAPLACE_PEER "df -B1 --output=avail '$mount' | tail -1; du -sb '$path' 2>/dev/null | cut -f1 || echo 0")
  if (-not $q.Count -or $q[0] -notmatch '^\d+$') { throw "$($job.n): $($env:LAPLACE_PEER) did not answer the room probe" }
  # Unrelated or obsolete files in the destination do not reduce the space this copy may need.
  $avail = [int64]$q[0]; $need = [int64]$total + 5GB
  Write-Host ("{0,-26} room: needs {1:N1} GiB (+5), {2:N1} GiB free on {3}" -f $job.n, (($need - 5GB)/1GB), ($avail/1GB), $mount)
  if ($need -gt $avail) { throw "$($job.n) does not fit on $mount" }
}
function Copy-Job($job) {
  Assert-Room $job
  $log = "$logs\robocopy\$($job.n).log"
  $ra = @($job.s, $job.d, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/FFT', '/R:2', '/W:5', '/MT:8', '/NP', "/UNILOG+:$log")
  $xd = @($job.xd | Where-Object { $_ }); if ($xd) { $ra += '/XD'; $ra += $xd }
  $xf = @($job.xf | Where-Object { $_ }); if ($xf) { $ra += '/XF'; $ra += $xf }
  & robocopy.exe @ra | Out-Null; $rc = $LASTEXITCODE
  Write-Host ("{0,-26} robocopy exit {1} ({2})" -f $job.n, $rc, $(if ($rc -lt 8) { 'ok' } else { 'FAILED: see ' + $log }))
  if ($rc -ge 8) { throw "$($job.n): robocopy failed with exit $rc; see $log" }
}

function Test-CopiedManifest($job) {
  $root = [IO.Path]::GetFullPath($job.d).TrimEnd('\') + '\'
  $count = 0
  foreach ($line in [IO.File]::ReadLines("$logs\manifests\$($job.n).tsv")) {
    if ($line.StartsWith('#') -or -not $line) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -ne 3 -or $parts[1] -notmatch '^\d+$' -or $parts[2] -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid backup manifest row' }
    $path = [IO.Path]::GetFullPath((Join-Path $root $parts[0]))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup manifest path escapes its destination' }
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($file.Length -ne [int64]$parts[1] -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $parts[2]) {
      throw "$($job.n): destination differs from the source manifest: $($parts[0])"
    }
    $count++
  }
  Write-Host "$($job.n): verified $count destination files against the source manifest"
}

if ($Only) {
  foreach ($name in $Only) { if ($name -notin $jobs.n) { throw "No backup job named $name in set $Set" } }
  $jobs = @($jobs | Where-Object n -in $Only)
}
if ($Plan) {
  $jobs | ForEach-Object { [pscustomobject]@{Set=$Set;Name=$_.n;Source=$_.s;Destination=$_.d;Exists=(Test-Path -LiteralPath $_.s);Required=[bool]$_.required;ManifestOnly=[bool]$_.manifestOnly} }
  return
}
if ($SkipManifest) { throw 'A backup requires a fresh source manifest; remove -SkipManifest.' }
foreach ($job in $jobs) {
  if ($job.required -and -not (Test-Path -LiteralPath $job.s -PathType Container)) { throw "Required backup source is missing: $($job.s)" }
}
New-Item -ItemType Directory -Force "$logs\manifests", "$logs\robocopy", "$logs\patches" | Out-Null
$copyLock = [IO.File]::Open((Join-Path $env:LAPLACE_BACKUP_LOGS 'copyoff.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
# the uncommitted edits in the dependency sources (LAPLACE_DEPSRC), kept as patches: the sources themselves are reinstalled
if ($s.Patches -and (Test-Path -LiteralPath $env:LAPLACE_DEPSRC)) {
  foreach ($r in Get-ChildItem $env:LAPLACE_DEPSRC -Directory) { if (Test-Path "$($r.FullName)\.git") {
    $st = git -C $r.FullName status --porcelain 2>$null; if ($st) { git -C $r.FullName diff > "$logs\patches\$($r.Name).patch"; $st | Set-Content "$logs\patches\$($r.Name).status.txt" } } }
}

foreach ($job in $jobs) {
  if ($Only -and $job.n -notin $Only) { continue }
  if ($job.n -like 'Models-*' -and -not $Models) { "{0,-26} on hold: models are not touched without -Models" -f $job.n; continue }
  if (-not (Test-Path $job.s)) { "{0,-26} (no source)" -f $job.n; continue }
  $m = if ($job.man) { $job.man } else { "$inbox\_manifest" }
  # A receipt describes the previous copy. It never exempts changing source files from a later backup.
  $receipt = "$logs\done\$($job.n)"
  if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt }
  Write-Manifest $job
  if (-not ($ManifestOnly -or $job.manifestOnly)) { Copy-Job $job; Test-CopiedManifest $job }
  if (Test-Path "$logs\manifests\$($job.n).tsv") { New-Item -ItemType Directory -Force $m | Out-Null; Copy-Item "$logs\manifests\$($job.n).tsv" $m -Force }
  if (-not ($ManifestOnly -or $job.manifestOnly)) {
    New-Item -ItemType Directory -Force "$logs\done" | Out-Null
    "verified $(Get-Date -Format o) manifest-sha256=$((Get-FileHash "$logs\manifests\$($job.n).tsv").Hash)" | Set-Content -LiteralPath $receipt
  }
}
if ($s.Patches -and (Get-ChildItem "$logs\patches" -File -ErrorAction SilentlyContinue)) { New-Item -ItemType Directory -Force "$inbox\_patches" | Out-Null; Copy-Item "$logs\patches\*" "$inbox\_patches" -Force }
} finally { $copyLock.Dispose() }

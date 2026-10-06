#Requires -Version 7
<#
  fingerprint.sh's counterpart on Windows: what this machine's build of Laplace makes, as one record, laid beside
  hart-server's record for the same commits (the deployment target writes its own after every deployment), and
  published beside it on the branch fingerprints of Laplace-Operations.
    pwsh -File fingerprint.ps1                 record, compare, publish
    pwsh -File fingerprint.ps1 -NoPublish      record and compare only
  The build is the one build.ps1 made under $LAPLACE_BUILD (or -Laplace PATH) for the checkouts under $LAPLACE_SRC: to
  compare with a deployment, build at the commits it names (its summary, or the branch fingerprints). The record:
  the commits, tier 0 and its flags made afresh into a scratch directory, the highway the last deployment generated,
  and the claims of each source of $LAPLACE_DETERMINISM decomposed twice (laplace ingest --claims, nothing loaded).
  Runs the engine inside the developer shell (its run-time DLLs), never outside it.
#>
param([string]$Laplace = '', [switch]$NoPublish, [string]$Out = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue)) -and (Test-Path $env:LAPLACE_DEVSHELL)) { . $env:LAPLACE_DEVSHELL *> $null }
$env:PATH = "$env:LAPLACE_PG_DIR\bin;$env:LAPLACE_ICU_DIR\bin64;$env:PATH"
if (-not $env:LAPLACE_DETERMINISM) { $env:LAPLACE_DETERMINISM = 'iso-639 open-english-wordnet' }
if (-not $Laplace) { $Laplace = Join-Path $env:LAPLACE_BUILD 'Laplace-Engine\icx-release\laplace.exe' }
if (-not (Test-Path $Laplace)) { Write-Error "no laplace at ${Laplace}: build.ps1 builds it"; exit 1 }
$owner = if ($env:LAPLACE_GITHUB) { $env:LAPLACE_GITHUB } else { 'SaltyPatron' }
$url = "https://github.com/$owner/Laplace-Operations.git"
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('laplace-fingerprint-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory $scratch | Out-Null

function Commit([string]$r) {
  $d = Join-Path $env:LAPLACE_SRC $r
  $c = git -c safe.directory='*' -C $d rev-parse --short=12 HEAD 2>$null
  if (-not $c) { return 'none' }
  if (git -c safe.directory='*' -C $d status --porcelain --untracked-files=no) { return "$c+dirty" }
  $c
}
function Fp([string[]]$lines) { foreach ($l in $lines) { if ($l -match '^fingerprint.* ([0-9a-f]{64})') { return $Matches[1] } }; '' }
function Run([string[]]$a, [hashtable]$envs = @{}) {
  $saved = @{}
  foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
  try { $o = & $Laplace @a 2>&1 | ForEach-Object { "$_" }; @{ out = @($o); rc = $LASTEXITCODE } }
  finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}
function Field([string[]]$rec, [string]$name) { ($rec | Where-Object { $_ -match "^$name\s" } | Select-Object -First 1) -replace "^$name\s+", '' }

try {
  $rec = [Collections.Generic.List[string]]::new()
  $rec.Add("machine     $env:COMPUTERNAME")
  $rec.Add("os          Windows $([Environment]::OSVersion.Version)")
  $rec.Add("cpu         $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim())")
  $rec.Add("compiler    $(& icx.exe --version 2>$null | Select-Object -First 1)")
  $rec.Add("made        $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
  foreach ($r in 'Laplace-Native', 'Laplace-Engine', 'Laplace-postgres', 'Laplace-Operations') {
    $rec.Add(('{0,-11} {1}' -f $r.Replace('Laplace-', '').ToLower(), (Commit $r)))
  }
  $t0 = Join-Path $scratch 'tier0.bin'
  $rec.Add("tier0       $(Fp (Run @('tier0', '-o', $t0)).out)")
  $rec.Add("flags       $(Fp (Run @('flags', '-o', (Join-Path $scratch 'tier0.flags')) @{ LAPLACE_TIER0 = $t0 }).out)")
  $hw = ''
  $hl = Get-ChildItem (Join-Path $env:LAPLACE_WORK 'logs\deploy\*\highway.log') -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
  if ($hl) { $hw = Fp (Get-Content $hl) }
  $rec.Add("highway     $hw")
  foreach ($s in ($env:LAPLACE_DETERMINISM -split '\s+' | Where-Object { $_ })) {
    $runs = @()
    foreach ($i in 1, 2) {
      $r = Run @('ingest', '--claims', $s) @{ LAPLACE_INGEST_ONE = '1'; LAPLACE_WORK = (Join-Path $scratch 'work') }
      if ($r.rc) { break }
      [string[]]$claims = @($r.out | Where-Object { $_.StartsWith('[') })
      [Array]::Sort($claims, [StringComparer]::Ordinal)
      $sha = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((($claims -join "`n") + "`n")))
      $runs += , @{ n = $claims.Count; h = [Convert]::ToHexString($sha).ToLower().Substring(0, 16) }
    }
    if ($runs.Count -lt 2) { $rec.Add("claims      $s failed"); continue }
    $rec.Add("claims      $s $($runs[0].n) $($runs[0].h)")
    if ("$($runs[0].n) $($runs[0].h)" -eq "$($runs[1].n) $($runs[1].h)") { $rec.Add("determinism $s same: twice $($runs[0].n) claims, $($runs[0].h)") }
    else { $rec.Add("determinism $s DIFFERS: $($runs[0].n) claims $($runs[0].h), then $($runs[1].n) claims $($runs[1].h)") }
  }
  if (-not $Out) { $Out = Join-Path $env:LAPLACE_WORK "fingerprint-$env:COMPUTERNAME.txt" }
  New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
  [IO.File]::WriteAllText($Out, (($rec -join "`n") + "`n"))
  $rec

  $key = "$((Field $rec 'native').Replace('+dirty', ''))-$((Field $rec 'engine').Replace('+dirty', ''))"
  $branch = Join-Path $scratch 'fingerprints'
  git clone -q --depth 20 --branch fingerprints $url $branch 2>$null
  $have = $LASTEXITCODE -eq 0
  ''; "against the other machines' records for $key"
  $differs = $false; $n = 0
  foreach ($o in (Get-ChildItem (Join-Path $branch "$key\*.txt") -ErrorAction SilentlyContinue)) {
    if ($o.BaseName -eq $env:COMPUTERNAME) { continue }
    $n++; $other = @(Get-Content $o.FullName); "  $($o.BaseName) ($(Field $other 'os'); made $(Field $other 'made'))"
    foreach ($f in 'tier0', 'flags', 'highway') {
      $a = Field $rec $f; $b = Field $other $f
      if (-not $a -or -not $b) { "    ${f}: not in both" } elseif ($a -eq $b) { "    ${f}: same ($a)" } else { "    ${f}: DIFFERS: $a here, $b there"; $differs = $true }
    }
    foreach ($c in ($rec | Where-Object { $_ -match '^claims\s' })) {
      $p = $c -split '\s+'
      $b = ($other | Where-Object { $_ -match "^claims\s+$([regex]::Escape($p[1]))\s" } | Select-Object -First 1) -replace '^claims\s+\S+\s+', ''
      if (-not $b) { "    claims $($p[1]): not decomposed there" }
      elseif ("$($p[2]) $($p[3])" -eq $b) { "    claims $($p[1]): same ($($p[2]), $($p[3]))" }
      else { "    claims $($p[1]): DIFFERS: $($p[2]) $($p[3]) here, $b there"; $differs = $true }
    }
  }
  if (-not $n) { "  no other machine has a record for $key yet" }
  $dirty = [bool]($rec | Where-Object { $_ -match '\+dirty' })
  if ($dirty) { 'not published: a checkout has changes not committed' }
  elseif (-not $NoPublish) {
    if (-not $have) {
      git clone -q --depth 1 $url $branch; git -C $branch checkout -q --orphan fingerprints; git -C $branch rm -rqf .
      [IO.File]::WriteAllText((Join-Path $branch 'README.md'), "# Fingerprints`n`nOne directory per pair of commits (Laplace-Native-Laplace-Engine), one record per machine: fingerprint.sh and fingerprint.ps1 write them, and compare a record with every other one beside it.`n")
    }
    New-Item -ItemType Directory -Force (Join-Path $branch $key) | Out-Null
    [IO.File]::WriteAllText((Join-Path $branch "$key\$env:COMPUTERNAME.txt"), (($rec -join "`n") + "`n"))
    git -C $branch add -A; git -C $branch commit -qm "${key}: $env:COMPUTERNAME"
    if ($LASTEXITCODE -eq 0) {
      foreach ($t in 1..5) { git -C $branch push -q origin fingerprints; if ($LASTEXITCODE -eq 0) { "published $key/$env:COMPUTERNAME.txt"; break }; git -C $branch pull -q --rebase origin fingerprints }
    }
  }
  if ($differs -or ($rec | Where-Object { $_ -match '^determinism .* DIFFERS' })) { exit 1 }
} finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }

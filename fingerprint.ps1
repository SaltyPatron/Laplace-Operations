#Requires -Version 7
<#
  fingerprint.sh's counterpart on Windows: what this machine's build of Laplace makes, as one record, laid beside
  hart-server's record for the same commits (the deployment target writes its own after every deployment), and
  published beside it on the branch fingerprints of Laplace-Operations.
    pwsh -File fingerprint.ps1                 record, compare, publish
    pwsh -File fingerprint.ps1 -NoPublish      record and compare only
    pwsh -File fingerprint.ps1 -Against DIR    record, and compare with the records (*.txt) in DIR in place of the branch's
    pwsh -File fingerprint.ps1 -Inputs         what this machine's results are made from: the lines of the record that say its data
  The build is the one build.ps1 made under $LAPLACE_BUILD (or -Laplace PATH) for the checkouts under $LAPLACE_SRC: to
  compare with a deployment, build at the commits it names (its summary, or the branch fingerprints). The record:
  the commits, tier 0 and its flags made afresh into a scratch directory, the highway the last deployment generated,
  and the claims of each source of $LAPLACE_DETERMINISM decomposed twice (laplace ingest --claims, nothing loaded).
  Runs the engine inside the developer shell (its run-time DLLs), never outside it.
#>
param([string]$Laplace = '', [switch]$NoPublish, [string]$Out = '', [switch]$Inputs, [string]$Against = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if (-not $env:LAPLACE_DETERMINISM) { $env:LAPLACE_DETERMINISM = 'iso-639 open-english-wordnet' }

# What the results are made from, as fingerprint.sh says it (the same lines, the same hashes): the Unicode data tier 0,
# its flags and the unicode source are read from, the ICU and the Unicode version it is of, the resources the highway
# was generated from, and the directory each of those sources and each source of $LAPLACE_DETERMINISM is read from. A
# tree is its files and one hash: of "path<TAB>bytes<TAB>sha256" for every file, paths with / and in byte order.
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Text;
public sealed class LaplaceByteOrder : IComparer<string> {
  public int Compare(string a, string b) {
    byte[] x = Encoding.UTF8.GetBytes(a), y = Encoding.UTF8.GetBytes(b); int n = Math.Min(x.Length, y.Length);
    for (int i = 0; i < n; i++) if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return x.Length.CompareTo(y.Length);
  }
}
'@
function Tree([string]$dir, [string]$except = '') {
  $root = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\')
  $rel = [Collections.Generic.List[string]]::new()
  foreach ($f in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
    $r = $f.Substring($root.Length + 1).Replace('\', '/'); if ($except -and $r.StartsWith($except, [StringComparison]::Ordinal)) { continue }
    if ($r.StartsWith('.') -or $r.Contains('/.')) { continue }       # a name that begins with a dot: the engine's walk does not read one
    $rel.Add($r) }
  $rel.Sort([LaplaceByteOrder]::new())
  $sb = [Text.StringBuilder]::new()
  foreach ($r in $rel) { $p = Join-Path $root $r; [void]$sb.Append("$r`t$((Get-Item -LiteralPath $p).Length)`t$((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower())`n") }
  "$($rel.Count) $([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sb.ToString()))).ToLower().Substring(0, 16))"
}
function HeaderValue([string]$header, [string]$name) {                       # a #define NAME "value" of a header
  $p = Join-Path $env:LAPLACE_ICU_DIR "include\unicode\$header"
  if (Test-Path $p) { foreach ($l in Get-Content $p) { if ($l -match "^#define $name `"(.*?)`"") { return $Matches[1] } } }; '' }
function RootOf([string]$source) {                                      # its first root that exists; of a pattern, the newest: as the engine resolves it
  $src = Join-Path $env:LAPLACE_SRC "Laplace-Engine\recipes\$source\source"; if (-not (Test-Path $src)) { return '' }
  foreach ($l in Get-Content $src) {
    if ($l -notmatch '^root\s+(\S+)') { continue }
    $p = [regex]::Replace($Matches[1], '\$([A-Za-z_][A-Za-z0-9_]*)', { param($m) [Environment]::GetEnvironmentVariable($m.Groups[1].Value) }).Replace('/', '\')
    $found = @(Resolve-Path -Path $p -ErrorAction SilentlyContinue | ForEach-Object ProviderPath | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($found.Count) { [string[]]$f = $found; [Array]::Sort($f, [LaplaceByteOrder]::new()); return $f[-1] }
  }; '' }
function HighwayLog { Get-ChildItem (Join-Path $env:LAPLACE_WORK 'logs\deploy\*\highway.log') -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 }
function InputLines {
  $u = Join-Path $env:LAPLACE_UCD 'Public\UCD\latest'                   # where tier0.c, flags.c and the unicode recipe read it
  if (Test-Path $u) {
    $v = 'unknown'; $age = Join-Path $u 'ucd\DerivedAge.txt'
    if ((Test-Path $age) -and ((Get-Content $age -TotalCount 1) -match '^# DerivedAge-([0-9.]+)\.txt')) { $v = $Matches[1] }
    "ucd         $v $(Tree $u 'charts/')"
  } else { 'ucd         none' }
  "icu         $(HeaderValue 'uvernum.h' 'U_ICU_VERSION') unicode $(HeaderValue 'uchar.h' 'U_UNICODE_VERSION')"
  $res = @(); $hl = HighwayLog; $in = $false
  if ($hl) { foreach ($l in Get-Content $hl) {
    if ($l -match '^laplace highway') { $in = $true; continue }; if (-not $in) { continue }; if ($l -match '^  slots:') { break }
    if ($l -cmatch '^  ([a-z][a-z0-9-]*) +[0-9n]') { $res += $Matches[1] } } }
  "resources   $($res -join ' ')"
  $seen = @{}
  foreach ($s in @($env:LAPLACE_DETERMINISM -split '\s+' | Where-Object { $_ }) + $res) {
    if ($seen[$s]) { continue }; $seen[$s] = $true; $d = RootOf $s
    if ($d) { "data        $s $(Tree $d) $(Split-Path $d -Leaf)" } else { "data        $s none" }
  }
}
if ($Inputs) { InputLines; exit 0 }

if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue)) -and (Test-Path $env:LAPLACE_DEVSHELL)) { . $env:LAPLACE_DEVSHELL *> $null }
$env:PATH = "$env:LAPLACE_PG_DIR\bin;$env:LAPLACE_ICU_DIR\bin64;$env:PATH"
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
# Laying two records side by side, as fingerprint.sh does. DataOf: a source's data as "files hash" (or none); Same: two
# values as same, differs, or unknown (one is not said: a record from before the inputs were); Both: two such answers
# as one (any differs: differs; else any unknown: unknown); Why: what a result's difference then is.
function DataOf([string[]]$rec, [string]$source) {
  foreach ($l in $rec) { if ($l -match "^data\s+$([regex]::Escape($source))\s+(none|[0-9]+ [0-9a-f]+)") { return $Matches[1] } }; '' }
function Same([string]$a, [string]$b) { if (-not $a -or -not $b) { 'unknown' } elseif ($a -ceq $b) { 'same' } else { 'differs' } }
function Both([string]$a, [string]$b) { if ($a -eq 'differs' -or $b -eq 'differs') { 'differs' } elseif ($a -eq 'unknown' -or $b -eq 'unknown') { 'unknown' } else { 'same' } }
function Why([string]$in) { switch ($in) { 'differs' { '(its inputs differ: not a difference of arithmetic)' } 'same' { '(from the same inputs: the machines compute differently)' } default { '(the inputs are not said in both records)' } } }

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
  foreach ($l in InputLines) { $rec.Add($l) }
  $t0 = Join-Path $scratch 'tier0.bin'
  $rec.Add("tier0       $(Fp (Run @('tier0', '-o', $t0)).out)")
  $rec.Add("flags       $(Fp (Run @('flags', '-o', (Join-Path $scratch 'tier0.flags')) @{ LAPLACE_TIER0 = $t0 }).out)")
  $hw = ''
  $hl = HighwayLog
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
  if ($Against) {                                                       # -Against DIR: the records (*.txt) in DIR, in place of the branch's; nothing is published
    New-Item -ItemType Directory -Force (Join-Path $branch $key) | Out-Null
    Copy-Item (Join-Path $Against '*.txt') (Join-Path $branch $key) -ErrorAction SilentlyContinue
    $have = $true; $NoPublish = $true
  } else {
    git clone -q --depth 20 --branch fingerprints $url $branch 2>$null
    $have = $LASTEXITCODE -eq 0
  }
  ''; "against the other machines' records for $key"
  $differs = $false; $n = 0
  foreach ($o in (Get-ChildItem (Join-Path $branch "$key\*.txt") -ErrorAction SilentlyContinue)) {
    if ($o.BaseName -eq $env:COMPUTERNAME) { continue }
    $n++; $other = @(Get-Content $o.FullName); "  $($o.BaseName) ($(Field $other 'os'); made $(Field $other 'made'))"
    # the inputs first: what differs in a result is then said to follow from them, or to be the machines' arithmetic
    # What fails: a result that differs from the same inputs (or from inputs one record does not say), ICU, the Unicode
    # version. A host's data differing does not: hosts hold different data by declaration (data.tsv's `once`).
    $a = Field $rec 'ucd'; $b = Field $other 'ucd'; $ucd = Same (($a -split ' ')[0]) (($b -split ' ')[0])      # the Unicode version: tier 0 and the flags are made from it
    switch (Same $a $b) { 'same' { "    ucd: same ($a)" } 'unknown' { "    ucd: not in both" } default { if ($ucd -eq 'same') { "    ucd: differs: $a here, $b there   (the same Unicode version; the files held differ)" } else { "    ucd: DIFFERS: $a here, $b there"; $differs = $true } } }
    $a = Field $rec 'icu'; $b = Field $other 'icu'
    switch (Same $a $b) { 'same' { "    icu: same ($a)" } 'differs' { "    icu: DIFFERS: $a here, $b there"; $differs = $true } default { "    icu: not in both" } }
    foreach ($s in ($rec | Where-Object { $_ -match '^data\s' } | ForEach-Object { ($_ -split '\s+')[1] })) {
      $a = DataOf $rec $s; $b = DataOf $other $s
      switch (Same $a $b) { 'same' { "    data ${s}: same ($a)" } 'differs' { "    data ${s}: differs: $a here, $b there" } default { "    data ${s}: not in both" } }
    }
    $hwin = $ucd; foreach ($s in ((Field $rec 'resources') -split '\s+' | Where-Object { $_ })) { $hwin = Both $hwin (Same (DataOf $rec $s) (DataOf $other $s)) }
    foreach ($f in 'tier0', 'flags', 'highway') {
      $a = Field $rec $f; $b = Field $other $f; $in = if ($f -eq 'highway') { $hwin } else { $ucd }
      switch (Same $a $b) { 'same' { "    ${f}: same ($a)" } 'differs' { if ($in -eq 'differs') { "    ${f}: differs: $a here, $b there   $(Why $in)" } else { "    ${f}: DIFFERS: $a here, $b there   $(Why $in)"; $differs = $true } } default { "    ${f}: not in both" } }
    }
    foreach ($c in ($rec | Where-Object { $_ -match '^claims\s' })) {
      $p = $c -split '\s+'; if ($p[2] -eq 'failed') { continue }
      $a = "$($p[2]) $($p[3])"
      $b = ($other | Where-Object { $_ -match "^claims\s+$([regex]::Escape($p[1]))\s" } | Select-Object -First 1) -replace '^claims\s+\S+\s+', ''
      $in = Both $ucd (Same (DataOf $rec $p[1]) (DataOf $other $p[1]))
      switch (Same $a $b) { 'same' { "    claims $($p[1]): same ($a)" } 'differs' { if ($in -eq 'differs') { "    claims $($p[1]): differs: $a here, $b there   $(Why $in)" } else { "    claims $($p[1]): DIFFERS: $a here, $b there   $(Why $in)"; $differs = $true } } default { "    claims $($p[1]): not decomposed there" } }
    }
  }
  if (-not $n) { "INCOMPLETE: no other machine has a record for $key; cross-machine equivalence was not verified" }
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
  if (-not $have -or -not $n) { exit 2 }
} finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }

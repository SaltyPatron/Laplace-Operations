<#
.SYNOPSIS
  Deploys the canonical Laplace agent files to every agent tool on this machine.

.DESCRIPTION
  Source of truth: Laplace-Operations/agents/AGENTS.md (core) and agents/skills/* (skills).

  The full core goes into each tool's GLOBAL instruction file, so it is loaded exactly once
  wherever the tool starts:
    ~/.gemini/GEMINI.md (Gemini / Antigravity), ~/.codex/AGENTS.md (Codex),
    ~/.copilot/copilot-instructions.md (Copilot CLI), ~/.claude/CLAUDE.md (Claude Code).
  Workspace- and repo-level files that tools also auto-load become short pointers, so the
  core is never injected twice.
  Skills are copied into every tool's skills directory.
  Each overwritten file is backed up first, to %LOCALAPPDATA%\Laplace\agent-backups\<stamp>\.

.EXAMPLE
  pwsh -File agents/sync.ps1 -WhatIf
  pwsh -File agents/sync.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$UserHome = $HOME,
  [string]$LaplaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)
$ErrorActionPreference = 'Stop'

$agents = $PSScriptRoot
$core = Join-Path $agents 'AGENTS.md'
$canonical = $core
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $env:LOCALAPPDATA "Laplace\agent-backups\$stamp"

$pointer = @"
# Laplace

Laplace agent rules are loaded globally from each tool's user instruction file. If they are not in your context, read ``$canonical`` before doing anything else.

- Deep byte-level reference: skill ``laplace-invention`` (``$(Join-Path $agents 'skills\laplace-invention\SKILL.md')``).
- Documentation: ``$(Join-Path $LaplaceRoot 'Laplace-Wiki\README.md')``. Code search: MCP server ``laplace-code``.
- Edit the canonical files in ``Laplace-Operations/agents/``, then run ``agents/sync.ps1``. Never edit the deployed copies.
"@

$globalTargets = @(
  (Join-Path $UserHome '.gemini\GEMINI.md'),
  (Join-Path $UserHome '.codex\AGENTS.md'),
  (Join-Path $UserHome '.copilot\copilot-instructions.md'),
  (Join-Path $UserHome '.claude\CLAUDE.md')
)
$pointerTargets = @(
  (Join-Path $UserHome 'AGENTS.md'),
  (Join-Path $UserHome 'GEMINI.md'),
  (Join-Path $UserHome '.gemini\config\GEMINI.md'),
  (Join-Path $LaplaceRoot 'AGENTS.md')
)
# Tracked repo copies stay full: hosted agents (GitHub Copilot coding agent, Codex cloud, CI) only see the repo.
$repoTargets = @(
  (Join-Path $LaplaceRoot 'Laplace\AGENTS.md'),
  (Join-Path $LaplaceRoot 'Laplace-Operations\AGENTS.md')
)
$worktreesRoot = Join-Path $LaplaceRoot '.worktrees'
if (Test-Path $worktreesRoot) {
  foreach ($wt in Get-ChildItem $worktreesRoot -Directory) {
    foreach ($candidate in @(
      (Join-Path $wt.FullName 'AGENTS.md'),
      (Join-Path $wt.FullName 'agents\AGENTS.md')
    )) {
      if (Test-Path $candidate) { $repoTargets += $candidate }
    }
  }
}
$skillRoots = @(
  (Join-Path $UserHome '.gemini\skills'),
  (Join-Path $UserHome '.gemini\antigravity\skills'),
  (Join-Path $UserHome '.codex\skills'),
  (Join-Path $UserHome '.copilot\skills'),
  (Join-Path $UserHome '.claude\skills')
)

function Backup([string]$path) {
  if (-not (Test-Path $path)) { return }
  $rel = ($path -replace '^[A-Za-z]:\\', '') -replace '[\\/:]', '_'
  New-Item -ItemType Directory -Force $backupRoot | Out-Null
  Copy-Item $path (Join-Path $backupRoot $rel) -Force
}

function Put([string]$path, [string]$text) {
  if ((Test-Path $path) -and ((Get-Content $path -Raw) -ceq $text)) { Write-Host "  unchanged  $path"; return }
  if ($PSCmdlet.ShouldProcess($path, 'write')) {
    Backup $path
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "  wrote      $path"
  }
}

$coreText = Get-Content $core -Raw
Write-Host 'Global core:'
foreach ($t in $globalTargets) { Put $t $coreText }
Write-Host 'Repo copies:'
foreach ($t in $repoTargets) { Put $t $coreText }
Write-Host 'Pointers:'
foreach ($t in $pointerTargets) { Put $t $pointer }
Write-Host 'Skills:'
foreach ($skill in Get-ChildItem (Join-Path $agents 'skills') -Directory) {
  foreach ($root in $skillRoots) {
    foreach ($f in Get-ChildItem $skill.FullName -Recurse -File) {
      $rel = $f.FullName.Substring($skill.FullName.Length + 1)
      Put (Join-Path $root (Join-Path $skill.Name $rel)) (Get-Content $f.FullName -Raw)
    }
  }
}
if (Test-Path $backupRoot) { Write-Host "Backups: $backupRoot" }

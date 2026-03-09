param(
  [Parameter(Mandatory = $true)]
  [string]$Workspace,
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }),
  [switch]$SkipCodexInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$assetsDir = Join-Path $scriptDir "assets"
$agentsSrc = Join-Path $assetsDir "AGENTS.md"
$skillName = "embedded-linux-hybrid-workflow"
$skillSrc = Join-Path (Join-Path $assetsDir "skills") $skillName

$agentsDst = Join-Path $Workspace "AGENTS.md"
$skillsDir = Join-Path $CodexHome "skills"
$skillDst = Join-Path $skillsDir $skillName

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $Workspace ".codex-bootstrap-backups\$timestamp"

function Require-Command {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [string]$DisplayName = $Name
  )

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "error: required command not found: $DisplayName"
  }
}

function Get-CodexVersion {
  $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
  if (-not $codexCommand) {
    return $null
  }

  try {
    return (& $codexCommand.Source --version 2>$null)
  } catch {
    return "unknown"
  }
}

function Ensure-CodexCli {
  $existingVersion = Get-CodexVersion
  if ($existingVersion) {
    Write-Host "[ok] codex already installed: $existingVersion"
    return
  }

  Require-Command node
  Require-Command npm.cmd "npm"

  Write-Host "[info] codex not found, installing @openai/codex ..."
  & npm.cmd install -g @openai/codex
  if ($LASTEXITCODE -ne 0) {
    throw "error: failed to install @openai/codex globally"
  }

  $installedVersion = Get-CodexVersion
  if ($installedVersion) {
    Write-Host "[ok] codex installed globally: $installedVersion"
    return
  }

  $npmGlobalBin = Join-Path $env:APPDATA "npm"
  Write-Warning "codex installed but not found in PATH yet. Reopen VS Code or ensure '$npmGlobalBin' is in PATH."
}

function Backup-IfExists {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  if (Test-Path $Source) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -Path $Source -Destination $Destination -Recurse -Force
  }
}

function Render-Agents {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  $content = Get-Content -Raw -Path $agentsSrc
  $rendered = $content.Replace("__CODEX_HOME__", ($CodexHome -replace "\\", "/"))
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Destination, $rendered, $utf8NoBom)
}

function Sync-Configs {
  if (-not (Test-Path $agentsSrc -PathType Leaf)) {
    throw "error: missing file: $agentsSrc"
  }

  if (-not (Test-Path $skillSrc -PathType Container)) {
    throw "error: missing directory: $skillSrc"
  }

  New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
  New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

  Backup-IfExists -Source $agentsDst -Destination (Join-Path $backupRoot "AGENTS.md")
  Backup-IfExists -Source $skillDst -Destination (Join-Path $backupRoot "skills\$skillName")

  Render-Agents -Destination $agentsDst

  if (Test-Path $skillDst) {
    Remove-Item -Path $skillDst -Recurse -Force
  }
  Copy-Item -Path $skillSrc -Destination $skillDst -Recurse -Force
}

if (-not $SkipCodexInstall) {
  Ensure-CodexCli
} else {
  Write-Host "[info] skip codex install"
}

Sync-Configs

if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
  Write-Warning "bash was not found in PATH. The embedded-linux-hybrid-workflow scripts are .sh files, so install Git Bash or use WSL before invoking them."
}

Write-Host "[done] bootstrap completed"
Write-Host "workspace: $Workspace"
Write-Host "codex_home: $CodexHome"
Write-Host "backup: $backupRoot"
Write-Host "next: run 'codex login'"

param(
  [Parameter(Mandatory = $true)]
  [string]$Workspace,
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $scriptDir "install.ps1") -Workspace $Workspace -CodexHome $CodexHome -SkipCodexInstall

[CmdletBinding()]
param(
  [string]$HostedUrl = 'http://SAH0235190:8788/',
  [string]$IconPath,
  [switch]$NoDesktop,
  [switch]$NoStartMenu,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$productName = 'SAMI Kanban'
$legacyProductName = 'SAMI Project Portfolio'
$uri = [Uri]$HostedUrl
if ($uri.Scheme -notin @('http', 'https')) { throw "HostedUrl must use http or https: $HostedUrl" }
$HostedUrl = $uri.AbsoluteUri

$localBase = Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer'
$localIcon = Join-Path $localBase 'assets\sami_project_portfolio_v2.ico'
$desktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($desktopRoot)) { $desktopRoot = Join-Path $env:USERPROFILE 'Desktop' }
$programsRoot = [Environment]::GetFolderPath('Programs')
$backupRoot = Join-Path $localBase ('client-launcher-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Get-FirstExistingFile {
  param([string[]]$Candidates)
  foreach ($candidate in $Candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  return $null
}

$iconCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($IconPath)) { $iconCandidates += $IconPath }
$iconCandidates += @(
  (Join-Path $PSScriptRoot 'assets\sami_project_portfolio_v2.ico'),
  (Join-Path $PSScriptRoot '..\assets\sami_project_portfolio_v2.ico'),
  (Join-Path $PSScriptRoot '..\dist\SAMI_Project_Portfolio_User_Installer\payload\assets\sami_project_portfolio_v2.ico'),
  $localIcon
)
$sourceIcon = Get-FirstExistingFile -Candidates $iconCandidates

function Backup-And-Move {
  param([string]$Path, [string]$RelativeName)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  $destination = Join-Path $backupRoot $RelativeName
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite backup: $destination" }
  Move-Item -LiteralPath $Path -Destination $destination
  Write-Host "Backed up legacy launcher: $Path -> $destination"
}

function New-HostedUrlShortcut {
  param([string]$Path)
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  $lines = @('[InternetShortcut]', "URL=$HostedUrl")
  if (Test-Path -LiteralPath $localIcon -PathType Leaf) {
    $lines += "IconFile=$localIcon"
    $lines += 'IconIndex=0'
  }
  [System.IO.File]::WriteAllText($Path, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Shortcut could not be created: $Path" }
}

New-Item -ItemType Directory -Path (Join-Path $localBase 'assets'), $backupRoot -Force | Out-Null
if ($sourceIcon -and ([System.IO.Path]::GetFullPath($sourceIcon) -ne [System.IO.Path]::GetFullPath($localIcon))) {
  Copy-Item -LiteralPath $sourceIcon -Destination $localIcon -Force
}

$targets = @()
if (-not $NoDesktop) { $targets += @{Root=$desktopRoot; Name="$productName.url"; Legacy="$legacyProductName.lnk"; Rel='Desktop'} }
if (-not $NoStartMenu) { $targets += @{Root=$programsRoot; Name="$productName.url"; Legacy="$legacyProductName.lnk"; Rel='StartMenu'} }
foreach ($target in $targets) {
  Backup-And-Move -Path (Join-Path $target.Root $target.Legacy) -RelativeName (Join-Path $target.Rel $target.Legacy)
  New-HostedUrlShortcut -Path (Join-Path $target.Root $target.Name)
}

$proxyPath = Join-Path $localBase 'Launch SAMI Project Portfolio.vbs'
if (Test-Path -LiteralPath $proxyPath -PathType Leaf) {
  Backup-And-Move -Path $proxyPath -RelativeName 'Launch SAMI Project Portfolio.vbs'
}
$proxyContent = @"
Option Explicit
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run "$HostedUrl", 1, False
"@
[System.IO.File]::WriteAllText($proxyPath, $proxyContent, [Text.UTF8Encoding]::new($false))

Write-Host "$productName hosted shortcut installed: $HostedUrl"
if (-not $NoLaunch) { Start-Process -FilePath $HostedUrl }

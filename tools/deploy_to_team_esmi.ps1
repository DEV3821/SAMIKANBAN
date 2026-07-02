[CmdletBinding()]
param(
  [string]$SourcePath = 'C:\Tools\SAMI-Kanban-WorkServer',
  [string]$TeamRoot,
  [string]$Version,
  [string]$Message = 'SAMI Project Portfolio update'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($TeamRoot)) { $TeamRoot = $env:SAMI_KANBAN_TEAM_ROOT }
if ([string]::IsNullOrWhiteSpace($TeamRoot)) { throw 'Team ESMI path is required. Set SAMI_KANBAN_TEAM_ROOT or run with -TeamRoot.' }
$SourcePath = [System.IO.Path]::GetFullPath($SourcePath)
$TeamRoot = [System.IO.Path]::GetFullPath($TeamRoot)
if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw "Source path not found: $SourcePath" }
if (-not (Test-Path -LiteralPath $TeamRoot -PathType Container)) { throw "Team ESMI path not found: $TeamRoot" }
if ($SourcePath.Equals($TeamRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'SourcePath and TeamRoot must be different folders.' }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-Date -Format 'yyyy.MM.dd.HHmmss' }

$versionPayload = [ordered]@{
  version = $Version
  releasedAt = (Get-Date).ToString('o')
  message = $Message
  requiresReload = $true
}
$sourceVersion = Join-Path $SourcePath 'data\app_version.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $sourceVersion) -Force | Out-Null
[System.IO.File]::WriteAllText($sourceVersion, (($versionPayload | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
$installerPayloadVersion = Join-Path $SourcePath 'dist\SAMI_Project_Portfolio_User_Installer\payload\data\app_version.json'
if (Test-Path -LiteralPath $installerPayloadVersion -PathType Leaf) {
  Copy-Item -LiteralPath $sourceVersion -Destination $installerPayloadVersion -Force
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $TeamRoot "backups\app-deploy-$stamp"
$files = @(
  'index.html','manifest.webmanifest','serve_kanban.ps1','run_kanban.bat','run_kanban_debug.bat','run_kanban_silent.vbs',
  'install_sami_project_portfolio.ps1','tools\bootstrap_kanban.ps1','tools\launch_sami_portfolio.vbs',
  'tools\deploy_to_team_esmi.ps1','data\app_version.json','README.md','assets\README.md'
)

function Deploy-File {
  param([string]$RelativePath)
  $source = Join-Path $SourcePath $RelativePath
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return }
  $destination = Join-Path $TeamRoot $RelativePath
  if (Test-Path -LiteralPath $destination -PathType Leaf) {
    $backup = Join-Path $backupRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
    Copy-Item -LiteralPath $destination -Destination $backup
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

foreach ($relative in $files) { Deploy-File $relative }
$assetRoot = Join-Path $SourcePath 'assets'
if (Test-Path -LiteralPath $assetRoot -PathType Container) {
  Get-ChildItem -LiteralPath $assetRoot -File -Recurse | ForEach-Object {
    $relative = $_.FullName.Substring($SourcePath.Length).TrimStart('\')
    Deploy-File $relative
  }
}

$installerSource = Join-Path $SourcePath 'dist\SAMI_Project_Portfolio_User_Installer'
if (Test-Path -LiteralPath $installerSource -PathType Container) {
  $installerDestination = Join-Path $TeamRoot 'installers\SAMI_Project_Portfolio_User_Installer'
  $installerBackup = Join-Path $backupRoot 'installers\SAMI_Project_Portfolio_User_Installer'
  if (Test-Path -LiteralPath $installerDestination -PathType Container) {
    New-Item -ItemType Directory -Path $installerBackup -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installerDestination -Force) {
      Copy-Item -LiteralPath $item.FullName -Destination $installerBackup -Recurse -Force
    }
  }
  New-Item -ItemType Directory -Path $installerDestination -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $installerSource -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $installerDestination -Recurse -Force
  }
}

Write-Host 'Deployment complete. Ask users to close their Kanban tab and click the SAMI Project Portfolio shortcut once to load the new UI.'
